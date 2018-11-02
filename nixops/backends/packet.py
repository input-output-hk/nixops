# -*- coding: utf-8 -*-
"""
A backend for packet.net.

"""
from __future__ import absolute_import
import os
import os.path
import time
import nixops.resources
from nixops.backends import MachineDefinition, MachineState
from nixops.nix_expr import Function, RawValue
import nixops.util
import nixops.known_hosts
import socket
import packet
from json import dumps
import pprint

class PacketDefinition(MachineDefinition):
    @classmethod
    def get_type(cls):
        return "packet"

    def __init__(self, xml, config):
        MachineDefinition.__init__(self, xml, config)
        self.access_key_id = config["packet"]["accessKeyId"]
        self.key_pair = config["packet"]["keyPair"]

    def show_type(self):
        return "packet [something]"


class PacketState(MachineState):
    @classmethod
    def get_type(cls):
        return "packet"

    state = nixops.util.attr_property("state", MachineState.MISSING, int)  # override
    accessKeyId = nixops.util.attr_property("packet.accessKeyId", None)

    def __init__(self, depl, name, id):
        MachineState.__init__(self, depl, name, id)
        self.name = name

    def get_ssh_name(self):
        retVal = None
        if self.use_private_ip_address:
            if not self.private_ipv4:
                raise Exception("Packet machine '{0}' does not have a private IPv4 address (yet)".format(self.name))
            retVal = self.private_ipv4
        else:
            if not self.public_ipv4:
                raise Exception("Packet machine ‘{0}’ does not have a public IPv4 address (yet)".format(self.name))
            retVal = self.public_ipv4
        return retVal


    def get_ssh_private_key_file(self):
        if self.private_key_file: return self.private_key_file
        if self._ssh_private_key_file: return self._ssh_private_key_file
        for r in self.depl.active_resources.itervalues():
            if isinstance(r, nixops.resources.packet_keypair.PacketKeyPairState) and \
                    r.state == nixops.resources.packet_keypair.PacketKeyPairState.UP and \
                    r.keypair_name == self.key_pair:
                return self.write_ssh_private_key(r.private_key)
        return None


    def get_ssh_flags(self, *args, **kwargs):
        file = self.get_ssh_private_key_file()
        super_flags = super(PacketState, self).get_ssh_flags(*args, **kwargs)
        return super_flags + (["-i", file] if file else [])

    def get_physical_spec(self):
        return Function("{ ... }", {
            ('config', 'boot', 'initrd', 'availableKernelModules'): [ "ata_piix", "uhci_hcd", "virtio_pci", "sr_mod", "virtio_blk" ],
            ('config', 'boot', 'loader', 'grub', 'device'): '/dev/vda',
            ('config', 'fileSystems', '/'): { 'device': '/dev/vda1', 'fsType': 'btrfs'},
            ('config', 'users', 'users', 'root', 'openssh', 'authorizedKeys', 'keys'): [self._ssh_public_key],
            ('config', 'networking', 'bonds', 'bond0', 'interfaces'): [ "enp1s0f0", "enp1s0f1"],
            ('config', 'networking', 'bonds', 'bond0', 'driverOptions'): {
                "mode": "802.3ad",
                "xmit_hash_policy": "layer3+4",
                "lacp_rate": "fast",
                "downdelay": "200",
                "miimon": "100",
                "updelay": "200",
              },
            ('config', 'networking', 'defaultGateway'): {
                "address": self.default_gateway,
                "interface": "bond0",
            },
            ('config', 'networking', 'defaultGateway6'): {
                "address": self.default_gatewayv6,
                "interface": "bond0",
            },
            ('config', 'networking', 'dhcpcd', 'enable'): False,
            ('config', 'networking', 'interfaces', 'bond0'): {
                "useDHCP": False,
                "ipv4": {
                    "addresses": [
                        { "address": self.public_ipv4, "prefixLength": self.public_cidr },
                        { "address": self.private_ipv4, "prefixLength": self.private_cidr },
                    ],
                    "routes": [
                        {
                            "address": "10.0.0.0",
                            "prefixLength": 8,
                            "via": self.private_gateway,
                        },
                    ],

                },
                "ipv6": {
                    "addresses": [
                        { "address": self.public_ipv6, "prefixLength": self.public_cidrv6 },
                    ],
                },
              },

        })

    def get_ssh_private_key_file(self):
        if self._ssh_private_key_file:
            return self._ssh_private_key_file
        else:
            return self.write_ssh_private_key(self._ssh_private_key)

    def create_after(self, resources, defn):
        # make sure the ssh key exists before we do anything else
        return {
            r for r in resources if
            isinstance(r, nixops.resources.packet_keypair.PacketKeyPairState)
        }

    def get_api_key(self):
        apikey = os.environ.get('PACKET_API_KEY', self.apikey)
        if apikey == None:
            raise Exception("PACKET_API_KEY must be set in the environment to deploy instances")
        return apikey

    def get_common_tags(self):
        tags = {'CharonNetworkUUID': self.depl.uuid,
                'CharonMachineName': self.name,
                'CharonStateFile': "{0}@{1}:{2}".format(getpass.getuser(), socket.gethostname(), self.depl._db.db_file)}
        if self.depl.name:
            tags['CharonNetworkName'] = self.depl.name
        return tags


    def destroy(self, wipe=False):
        self.log("destroying instance {}".format(self.subid))
        vultr = Vultr(self.get_api_key())
        try:
            vultr.server_destroy(self.subid)
        except VultrError:
            self.log("An error occurred destroying instance. Assuming it's been destroyed already.")
        self.public_ipv4 = None
        self.subid = None

    def create(self, defn, check, allow_reboot, allow_recreate):
        self.manager = packet.Manager(auth_token=defn.access_key_id)
        kp = self.depl.get_typed_resource(defn.key_pair, 'packet-keypair')
        common_tags = self.get_common_tags()
        tags = {'Name': "{0} [{1}]".format(self.depl.description, self.name)}
        tags.update(defn.tags)
        tags.update(common_tags)
        self.log_start("creating packet device ...")
        instance = self.manager.create_device(
            hostname=self.name,
            facility=defn.facility,
            user_ssh_keys=[kp.keypair_id],
            operating_system='nixos_18_03',
            plan=defn.plan,
            project=defn.project,
            tags=tags
        )

        self.vm_id = instance.id
        self.log("instance id: " + self.vm_id)
        while server_info['status'] == 'pending' or server_info['server_state'] != 'ok':
            server_info = vultr.server_list()[subid]
            time.sleep(1)
            self.log_continue("[status: {} state: {}] ".format(server_info['status'], server_info['server_state']))
            if server_info['status'] == 'active' and server_info['server_state'] == 'ok':
                # vultr sets ok before locked when restoring snapshot. Need to make sure we're really ready.
                time.sleep(10)
                server_info = vultr.server_list()[subid]
        if server_info['status'] != 'active' or server_info['server_state'] != 'ok':
            raise Exception("unexpected status: {}/{}".format(server_info['status'],server_info['server_state']))
        addresses = instance.ip_addresses
        for address in addresses:
           if address["public"] and address["address_family"] == 4:
               self.public_ipv4 = address["address"]
               self.default_gateway = address["gateway"]
               self.public_cidr = address["cidr"]
           if address["public"] and address["address_family"] == 6:
               self.public_ipv6 = address["address"]
               self.default_gatewayv6 = address["gateway"]
               self.public_cidrv6 = address["cidr"]
           if  not address["public"] and address["address_family"] == 4:
               self.private_ipv4 = address["address"]
               self.private_gateway = address["gateway"]
               self.private_cidr = address["cidr"]

        self.log_end("{}".format(self.public_ipv4))
        self.wait_for_ssh()

    def switch_to_configuration(self, method, sync, command=None):
        res = super(PacketState, self).switch_to_configuration(method, sync, command)
        if res == 0:
            self._ssh_public_key_deployed = True
        return res

