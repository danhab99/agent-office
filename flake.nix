{
  description = "Agent Office — AI-powered virtual office simulation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # ── NixOS module ──────────────────────────────────────────────────────
      # Defined outside of per-system scope so it can be imported as
      #   inputs.agent-office.nixosModules.default
      nixosModule = { config, lib, pkgs, ... }:
        let
          cfg = config.services.agent-office;
          inherit (lib) mkEnableOption mkOption mkIf types literalExpression;
        in
        {
          options.services.agent-office = {
            enable = mkEnableOption "Agent Office AI virtual office simulation";

            port = mkOption {
              type = types.port;
              default = 3000;
              description = ''
                TCP port on which the Agent Office server (Colyseus/Express) listens.
              '';
            };

            uiPort = mkOption {
              type = types.port;
              default = 8080;
              description = ''
                TCP port on which the Agent Office UI (nginx) listens.
              '';
            };

            dataDir = mkOption {
              type = types.path;
              default = "/var/lib/agent-office";
              description = ''
                Directory used for persistent storage (SQLite databases).
                The directory is created automatically and owned by the
                <literal>agent-office</literal> system user.
              '';
            };

            ollamaUrl = mkOption {
              type = types.str;
              default = "http://localhost:11434";
              example = "http://192.168.1.10:11434";
              description = ''
                Base URL of the Ollama inference server used by the agents
                for language-model completions and embedding generation.
              '';
            };

            tavilyApiKey = mkOption {
              type = types.str;
              default = "";
              description = ''
                Optional Tavily API key enabling web search for agents.
                When left empty, agents fall back to DuckDuckGo.
              '';
            };

            serverPackage = mkOption {
              type = types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.server;
              defaultText = literalExpression "agent-office.packages.\${system}.server";
              description = "The Agent Office server package to use.";
            };

            uiPackage = mkOption {
              type = types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.ui;
              defaultText = literalExpression "agent-office.packages.\${system}.ui";
              description = "The Agent Office UI package (pre-built static assets) to use.";
            };
          };

          config = mkIf cfg.enable {
            # Ensure the data directory exists before services start.
            systemd.tmpfiles.rules = [
              "d '${cfg.dataDir}' 0750 agent-office agent-office - -"
            ];

            users.users.agent-office = {
              isSystemUser = true;
              group = "agent-office";
              home = cfg.dataDir;
              description = "Agent Office service user";
            };

            users.groups.agent-office = { };

            # ── Server ──────────────────────────────────────────────────────
            systemd.services.agent-office-server = {
              description = "Agent Office server (Colyseus/Express)";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              environment = {
                PORT = toString cfg.port;
                DATABASE_URL = "sqlite:${cfg.dataDir}/office.db";
                DATA_DIR = cfg.dataDir;
                OLLAMA_URL = cfg.ollamaUrl;
              } // lib.optionalAttrs (cfg.tavilyApiKey != "") {
                TAVILY_API_KEY = cfg.tavilyApiKey;
              };

              serviceConfig = {
                ExecStart = "${cfg.serverPackage}/bin/agent-office-server";
                WorkingDirectory = cfg.dataDir;
                User = "agent-office";
                Group = "agent-office";
                Restart = "on-failure";
                RestartSec = "5s";

                # Hardening
                NoNewPrivileges = true;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ReadWritePaths = [ cfg.dataDir ];
                ProtectHome = true;
              };
            };

            # ── UI (nginx serving static assets) ────────────────────────────
            systemd.services.agent-office-ui = {
              description = "Agent Office UI (nginx static server)";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" "agent-office-server.service" ];

              # Write a runtime nginx.conf with the configured ports/upstream,
              # then start nginx in the foreground.
              script =
                let
                  nginxConf = pkgs.writeText "agent-office-nginx.conf" ''
                    error_log stderr;
                    pid /run/agent-office-ui/nginx.pid;

                    events {}

                    http {
                      include ${pkgs.nginx}/conf/mime.types;
                      default_type application/octet-stream;
                      access_log /dev/stdout;

                      client_body_temp_path /run/agent-office-ui/tmp;
                      proxy_temp_path       /run/agent-office-ui/tmp;
                      fastcgi_temp_path     /run/agent-office-ui/tmp;
                      uwsgi_temp_path       /run/agent-office-ui/tmp;
                      scgi_temp_path        /run/agent-office-ui/tmp;

                      server {
                        listen ${toString cfg.uiPort};
                        server_name localhost;
                        root ${cfg.uiPackage}/share/agent-office-ui;
                        index index.html;

                        # SPA fallback
                        location / {
                          try_files $uri $uri/ /index.html;
                        }

                        # WebSocket proxy for Colyseus matchmaking
                        location /matchmake/ {
                          proxy_pass http://127.0.0.1:${toString cfg.port};
                          proxy_http_version 1.1;
                          proxy_set_header Upgrade $http_upgrade;
                          proxy_set_header Connection "upgrade";
                        }

                        location /ws {
                          proxy_pass http://127.0.0.1:${toString cfg.port};
                          proxy_http_version 1.1;
                          proxy_set_header Upgrade $http_upgrade;
                          proxy_set_header Connection "upgrade";
                        }

                        # REST API proxy
                        location /api/ {
                          proxy_pass http://127.0.0.1:${toString cfg.port};
                        }
                      }
                    }
                  '';
                in
                ''
                  mkdir -p /run/agent-office-ui/tmp
                  exec ${pkgs.nginx}/bin/nginx -c ${nginxConf} -g 'daemon off;'
                '';

              serviceConfig = {
                RuntimeDirectory = "agent-office-ui";
                User = "agent-office";
                Group = "agent-office";
                Restart = "on-failure";
                RestartSec = "5s";

                # Hardening
                NoNewPrivileges = true;
                PrivateTmp = false;
                ProtectSystem = "strict";
                ProtectHome = true;
              };
            };
          };
        };
    in
    {
      nixosModules.agent-office = nixosModule;
      nixosModules.default = nixosModule;
    }
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # ── Shared workspace build ──────────────────────────────────────────
        # Compiles all TypeScript packages in the npm workspace.
        #
        # The package-lock.json is committed to the repository.  If you update
        # dependencies, regenerate it with `npm install`, then re-pin the hash:
        #   nix run nixpkgs#prefetch-npm-deps -- package-lock.json
        workspaceBuilt = pkgs.stdenv.mkDerivation {
          pname = "agent-office-workspace";
          version = "1.0.0";
          src = ./.;

          nativeBuildInputs = [
            pkgs.nodejs_20
            pkgs.npmHooks.npmConfigHook
            # sqlite3 is a native addon; node-gyp needs Python, pkg-config, and
            # the sqlite headers to compile it.
            pkgs.python3
            pkgs.pkg-config
            pkgs.nodePackages.node-gyp
          ];

          # buildInputs carries the sqlite runtime + headers into the build
          # environment so node-gyp can find libsqlite3.
          buildInputs = [ pkgs.sqlite ];

          # Explicitly wire up Python and the sqlite prefix so npm's bundled
          # node-gyp finds them even when PATH-based lookup returns empty (which
          # happens in the Nix sandbox during patchPhase).  These env vars are
          # set for every phase, including the npmConfigHook patchPhase where
          # `npm install` (and the sqlite3 postinstall) runs.
          npm_config_python = "${pkgs.python3}/bin/python3";
          npm_config_sqlite = "${pkgs.sqlite.dev}";

          npmDeps = pkgs.fetchNpmDeps {
            name = "agent-office-npm-deps";
            src = ./.;
            # This hash must match the current package-lock.json.
            # If it is wrong, run:
            #   nix run nixpkgs#prefetch-npm-deps -- package-lock.json
            # and paste the output here.
            hash = "";
          };

          buildPhase = ''
            npm run build --workspace=@agent-office/core
            npm run build --workspace=@agent-office/adapters
            npm run build --workspace=@agent-office/server
            npm run build --workspace=@agent-office/ui
          '';

          installPhase = ''
            cp -r . $out
          '';
        };

        # ── Server package ──────────────────────────────────────────────────
        # Installs the compiled Colyseus/Express server along with a wrapper
        # script that invokes it via node.
        server = pkgs.stdenv.mkDerivation {
          pname = "agent-office-server";
          version = "1.0.0";
          src = workspaceBuilt;
          dontBuild = true;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            # Server runtime files
            mkdir -p $out/lib/agent-office-server

            cp -r packages/server/dist              $out/lib/agent-office-server/dist
            cp    packages/server/package.json       $out/lib/agent-office-server/
            cp -r node_modules                       $out/lib/agent-office-server/node_modules

            # Resolve workspace symlinks so the store path is self-contained.
            for pkg in core adapters; do
              rm -rf $out/lib/agent-office-server/node_modules/@agent-office/$pkg
              cp -r packages/$pkg/dist \
                $out/lib/agent-office-server/node_modules/@agent-office/$pkg
              cp packages/$pkg/package.json \
                $out/lib/agent-office-server/node_modules/@agent-office/$pkg/
            done

            # Wrapper binary
            makeWrapper ${pkgs.nodejs_20}/bin/node $out/bin/agent-office-server \
              --add-flags "$out/lib/agent-office-server/dist/index.js"
          '';
        };

        # ── UI package ──────────────────────────────────────────────────────
        # Installs only the pre-built static web assets produced by Vite.
        ui = pkgs.stdenv.mkDerivation {
          pname = "agent-office-ui";
          version = "1.0.0";
          src = workspaceBuilt;
          dontBuild = true;

          installPhase = ''
            mkdir -p $out/share/agent-office-ui
            cp -r packages/ui/dist/. $out/share/agent-office-ui/
          '';
        };
      in
      {
        packages = { inherit server ui; default = server; };

        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.nodejs_20 pkgs.nginx ];
        };
      });
}
