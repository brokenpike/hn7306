{
  pkgs,
  inputs,
  ...
}:

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
  # Home Manager release this config was first written for. Do not bump this
  # when upgrading; see the Home Manager release notes before changing it.
  home.stateVersion = "24.05";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
