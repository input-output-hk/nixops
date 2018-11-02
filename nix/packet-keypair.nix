{ config, lib, uuid, name, ... }:

with lib;

{

  options = {

    name = mkOption {
      default = "charon-${uuid}-${name}";
      type = types.str;
      description = "Name of the Packet key pair.";
    };


    accessKeyId = mkOption {
      default = "";
      type = types.str;
      description = "The Packet Access Key ID.";
    };

  };

  config._type = "packet-keypair";

}
