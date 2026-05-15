{
  cfg,
  lib,
}: let
  useSecrets = !cfg.database.useInsecureHardcodedPassword;
  useAuthSecrets = !cfg.auth.useInsecureHardcodedSecret;

  enabledSecrets = lib.concatLists [
    (lib.optional useSecrets "postgres_password")
    (lib.optional useAuthSecrets "auth_secret")
  ];

  dockerSecretNames = {
    postgres_password = "dokploy_postgres_password";
    auth_secret = "dokploy_auth_secret";
  };

  passwordSecrets = lib.optionalAttrs useSecrets {
    secrets = [
      {
        source = "postgres_password";
        target = "/run/secrets/postgres_password";
      }
    ];
  };

  dokploySecrets = lib.optionalAttrs (enabledSecrets != []) {
    secrets =
      map (name: {
        source = name;
        target = "/run/secrets/${name}";
      })
      enabledSecrets;
  };

  passwordEnv =
    if useSecrets
    then {POSTGRES_PASSWORD_FILE = "/run/secrets/postgres_password";}
    else {POSTGRES_PASSWORD = "\${POSTGRES_PASSWORD}";};

  authEnv =
    if useAuthSecrets
    then {BETTER_AUTH_SECRET_FILE = "/run/secrets/auth_secret";}
    else {BETTER_AUTH_SECRET = "\${BETTER_AUTH_SECRET}";};

  allSecrets = lib.listToAttrs (map (name: {
      inherit name;
      value = {
        external = true;
        name = dockerSecretNames.${name};
      };
    })
    enabledSecrets);
in
  {
    version = "3.8";

    services = {
      postgres =
        {
          image = "postgres:16";
          environment =
            {
              POSTGRES_USER = "dokploy";
              POSTGRES_DB = "dokploy";
            }
            // passwordEnv;
          volumes = [
            "dokploy-postgres-database:/var/lib/postgresql/data"
          ];
          networks = {
            dokploy-network = {
              aliases = ["dokploy-postgres"];
            };
          };
          deploy = {
            placement.constraints = ["node.role == manager"];
            restart_policy.condition = "any";
          };
        }
        // passwordSecrets;

      redis = {
        image = "redis:7";
        volumes = [
          "redis-data-volume:/data"
        ];
        networks = {
          dokploy-network = {
            aliases = ["dokploy-redis"];
          };
        };
        deploy = {
          placement.constraints = ["node.role == manager"];
          restart_policy.condition = "any";
        };
      };

      dokploy =
        {
          inherit (cfg) image;
          environment =
            {
              ADVERTISE_ADDR = "\${ADVERTISE_ADDR}";
            }
            // passwordEnv // authEnv // cfg.environment;
          networks = {
            dokploy-network = {
              aliases = ["dokploy-app"];
            };
          };
          volumes = [
            "/var/run/docker.sock:/var/run/docker.sock"
            "${cfg.dataDir}:/etc/dokploy"
            "dokploy-docker-config:/root/.docker"
          ];
          depends_on = ["postgres" "redis"];
          deploy =
            {
              replicas = 1;
              placement.constraints = ["node.role == manager"];
              update_config = {
                parallelism = 1;
                order = "stop-first";
              };
              restart_policy.condition = "any";
            }
            // lib.optionalAttrs cfg.lxc {
              endpoint_mode = "dnsrr";
            };
        }
        // dokploySecrets
        // lib.optionalAttrs (cfg.port != null) {
          ports = let
            parts = lib.splitString ":" cfg.port;
            len = builtins.length parts;
          in
            if cfg.hostPortMode
            then [
              ({
                  target = lib.strings.toInt (lib.last parts);
                  published = lib.strings.toInt (builtins.elemAt parts (len - 2));
                  mode = "host";
                }
                // lib.optionalAttrs (len == 3) {
                  host_ip = builtins.head parts;
                })
            ]
            else [cfg.port];
        };
    };

    networks = {
      dokploy-network = {
        name = "dokploy-network";
        driver = "overlay";
        attachable = true;
      };
    };

    volumes = {
      dokploy-postgres-database = {};
      redis-data-volume = {};
      dokploy-docker-config = {};
    };
  }
  // lib.optionalAttrs (allSecrets != {}) {
    secrets = allSecrets;
  }
