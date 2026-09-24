{
  lib,
  osConfig,
  pkgs,
  inputs,
  ...
}:

let
  llm = osConfig.local.llm;
in
{
  home.username = "scott";
  home.homeDirectory = "/home/scott";

  # Tip: in helix, select the list and pipe it through `sort` to alphabetize
  home.packages = with pkgs; [
    alacritty
    brave
    btop
    claude-code
    cowsay
    deadnix
    direnv
    evince
    fish
    git-credential-manager
    gnomeExtensions.tiling-shell # GNOME only
    grc
    htop
    hunspell
    hunspellDicts.nb-no
    languagetool
    lazygit
    libreoffice-stable
    microsoft-edge
    nix-output-monitor
    obsidian
    tilix
    tmux
    uv
    vscode
    wl-clipboard # helix system clipboard (space + y yanks to it)
    zeroad
  ];

  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [
      wlrobs
      obs-backgroundremoval
      obs-pipewire-audio-capture
    ];
  };
  programs.helix = {
    enable = true;
    defaultEditor = true;
    settings = {
      #theme = "autumn_night_transparent";
      theme = "ao";
      editor.cursor-shape = {
        normal = "block";
        insert = "bar";
        select = "underline";
      };
    };
    languages.language = [
      {
        name = "nix";
        auto-format = true;
        formatter.command = "${pkgs.nixfmt}/bin/nixfmt";
      }
    ];
    themes = {
      autumn_night_transparent = {
        "inherits" = "autumn_night";
        "ui.background" = { };
      };
    };
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set fish_greeting # Disable greeting
    '';
    plugins = [
      # Enable a plugin (here grc for colorized command output) from nixpkgs
      {
        name = "grc";
        src = pkgs.fishPlugins.grc.src;
      }
      # Plugin packaged by hand from GitHub
      {
        name = "z";
        src = pkgs.fetchFromGitHub {
          owner = "jethrokuan";
          repo = "z";
          rev = "e0e1b9dfdba362f8ab1ae8c1afc7ccf62b89f7eb";
          sha256 = "0dbnir6jbwjpjalz14snzd3cgdysgcs3raznsijd6savad3qhijc";
        };
      }
    ];
  };

  programs.firefox = {
    enable = true;
    profiles.default.settings = {
      "widget.gtk.libadwaita-colors.enabled" = false;
      "browser.theme.native-theme" = false;
    };
    configPath = ".mozilla/firefox";
  };
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "brokenpike";
        email = "brokenpike@garmr.org";
      };
      credential = {
        helper = "manager";
        credentialStore = "cache";
      };
    };
    signing.format = "openpgp";
  };
  programs.kitty = {
    enable = true;
    settings = {
      shell = "${pkgs.fish}/bin/fish";
    };
  };

  # OpenCode coding agent, using the local Ollama server (see
  # hosts/<name>/ollama.nix). It runs as scott with scott's permissions, unlike
  # Hermes, so it asks before editing files or running commands. The model and
  # context come from llm.nix; a host without a local model gets no OpenCode.
  programs.opencode = lib.mkIf (llm.model != null) {
    enable = true;
    settings = {
      "$schema" = "https://opencode.ai/config.json";

      # Hermes uses the same model on the same server. Different names would
      # make Ollama unload and reload the model on every switch, so both read
      # local.llm.model. It also serves the small helper tasks.
      model = "ollama/${llm.model}";
      small_model = "ollama/${llm.model}";

      autoupdate = false; # the version comes from nixpkgs
      share = "disabled"; # never upload sessions to opencode.ai

      provider.ollama = {
        npm = "@ai-sdk/openai-compatible";
        name = "Ollama (local)";
        options.baseURL = "http://127.0.0.1:11434/v1";
        # OpenCode only offers the models declared here. The context equals the
        # server's OLLAMA_CONTEXT_LENGTH, so it matches Hermes.
        models = lib.genAttrs (lib.unique ([ llm.model ] ++ llm.extraModels)) (m: {
          name = "${m} (local)";
          limit = {
            context = llm.contextLength;
            output = 16384;
          };
        });
      };

      # Reading files is allowed by default (except .env). Rules are matched
      # top to bottom and the last match wins.
      permission = {
        edit = "ask";
        webfetch = "ask";
        websearch = "ask";
        bash = {
          "*" = "ask";
          "git diff" = "allow";
          "git diff *" = "allow";
          "git log" = "allow";
          "git log *" = "allow";
          "git status" = "allow";
          "git status *" = "allow";
          "git push *" = "deny";
          "rm *" = "deny";
          "sudo *" = "deny";
        };
      };
    };
  };
  # Home Manager release this config was first written for. Do not bump this
  # when upgrading; see the Home Manager release notes before changing it.
  home.stateVersion = "24.05";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
