{
  pkgs,
  config,
  lib,
  ...
}:
let
  cfg = config.services.site-exporter;
  staticUser = cfg.user != null && cfg.group != null;
in
{
  options.services.site-exporter = {
    enable = lib.mkEnableOption "a Prometheus exporter for Caturday's personal site";
    package = lib.mkPackageOption pkgs "site-exporter" { };

    user = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "site-exporter";
      description = ''
        User account under which to run this program. Defaults to [`DynamicUser`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#DynamicUser=)
        when set to `null`.

        The user will automatically be created, if this option is set to a non-null value.
      '';
    };
    group = lib.mkOption {
      type = with lib.types; nullOr str;
      default = cfg.user;
      defaultText = lib.literalExpression "config.services.site-exporter.user";
      example = "site-exporter";
      description = ''
        Group under which to run this program. Only used when `services.site-exporter.user` is set.

        The group will automatically be created, if this option is set to a non-null value.
      '';
    };

    interface = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "[::]";
      description = "Interface to listen on";
    };
    port = lib.mkOption {
      type = with lib.types; nullOr number;
      default = null;
      example = 8080;
      description = "Port to listen on";
    };
    dbUrl = lib.mkOption {
      type = lib.types.str;
      example = "postgresql://localhost/db";
      description = "PostgreSQL connection URL";
    };
  };

  config = lib.mkIf cfg.enable {
    users = lib.mkIf staticUser {
      users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
      };
      groups.${cfg.group} = { };
    };
    systemd.services.site-exporter = {
      description = "A Prometheus exporter for Caturday's personal site.";
      requires = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig =
        lib.optionalAttrs staticUser {
          User = cfg.user;
          Group = cfg.group;
        }
        // {
          ExecStart = lib.concatStringsSep " " (
            [
              (lib.getExe cfg.package)
            ]
            ++ lib.optional (cfg.interface != null || cfg.port != null) (
              if cfg.interface == null then "127.0.0.1" else cfg.interface
            )
            ++ lib.optional (cfg.port != null) (toString cfg.port)
          );
          Environment = [ "DB_URL=${cfg.dbUrl}" ];
          DynamicUser = !staticUser;
        };
    };
  };
}
