# Configuration specific to the Amazon Route 53 service.

{ config, lib, ... }:

with lib;

{

  ###### interface

  options = {

    deployment.route53.accessKeyId = mkOption {
      default = "";
      example = "AKIAIEMEJZVMPOHZWKZQ";
      type = types.str;
      description = ''
        The AWS Access Key ID.  If left empty, it defaults to the
        contents of the environment variables
        <envar>EC2_ACCESS_KEY</envar> or
        <envar>AWS_ACCESS_KEY_ID</envar> (in that order).  The
        corresponding Secret Access Key is not specified in the
        deployment model, but looked up in the file
        <filename>~/.ec2-keys</filename>, which should specify, on
        each line, an Access Key ID followed by the corresponding
        Secret Access Key. If the lookup was unsuccessful it is continued
        in the standard AWS tools <filename>~/.aws/credentials</filename> file.
        If it does not appear in these files, the
        environment variables
        <envar>EC2_SECRET_KEY</envar> or
        <envar>AWS_SECRET_ACCESS_KEY</envar> are used.
      '';
    };

    # FIXME: hostName is a misnomer; rename to dnsName or something like that.
    deployment.route53.hostName = mkOption {
      default = "";
      example = "test.x.logicblox.com";
      type = types.str;
      description = ''
        The DNS hostname to bind the public IP address to.
      '';
    };

    deployment.route53.ttl = mkOption {
      default = 300;
      example = 300;
      type = types.int;
      description = ''
        The time to live (TTL) for the A record created for the
        specified DNS hostname.
      '';
    };

    deployment.route53.usePublicDNSName = mkOption {
      default = false;
      type = types.bool;
      description = ''
        Whether to create a CNAME record with the instance's public DNS name.
        This will resolve inside AWS to a private IP and outside AWS to
        the public IP.
      '';
    };

    deployment.route53.multiValueSetId = mkOption {
      default = null;
      example = 42;
      type = types.nullOr types.int;
      description = ''
        When non-null, this turns the RRSet entry into a member of a multi-value family.
      '';
    };

  };


  ###### implementation

  config = mkIf (config.deployment.targetEnv == "ec2") {};

}
