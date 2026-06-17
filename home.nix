# config,
{
  pkgs,
  inputs,
  ...
}:

{
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "scott";
  home.homeDirectory = "/home/scott";
  #home.sessionVariables.EDITOR = "hx";
  # use select  "| sort " to make alphabetical

  home.packages = with pkgs; [
    #inputs.nixpkgs-stable.legacyPackages."x86_64-linux".btop
    alacritty
    brave
    btop
    cowsay
    deadnix
    direnv
    evince
    fish
    #gimp
    git-credential-manager
    grc
    htop
    hunspell
    hunspellDicts.nb-no
    hunspellDicts.th_TH
    hunspellDicts.uk_UA
    inkscape-with-extensions
    #    kdePackages.kdenlive
    languagetool
    lazygit
    libreoffice-fresh
    miro
    microsoft-edge
    nix-output-monitor
    #signald
    obsidian
    signal-desktop
    #stable.chromium
    #stable.vim
    #stable.zeroad
    tesseract
    tilix
    tmux
    vivaldi
    vscode
    #wl-clipboard-rs# did not enable the hx system clipboard
    wl-clipboard # space + "y" yanks to system clipboard
    zed-editor
    #    zellij
    wineWow64Packages.staging
  ];
  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [
      wlrobs
      obs-backgroundremoval
      obs-pipewire-audio-capture
    ];
  };

  programs.yazi = {
    enable = true;
    # flavors = {
    #   catppuccin-mocha = pkgs.fetchFromGitHub {
    #     owner = "yazi-rs";
    #     repo = "flavors";
    #     rev = "main";
    #     sha256 = "sha256-9hw6+yDI1KMl0e33ZMnFlitS9eE/dG5qW8b+E7k5Oks=";
    #     sparseCheckout = [ "catppuccin-mocha.yazi" ];
    #   };
    # };
    # theme = {
    #   flavor = {
    #     dark = "dracula";
    #     light = "gruvbox";
    #   };
    # };
    shellWrapperName = "y";
    settings = {
      opener = {
        edit = [
          {
            block = true;
            run = "hx \"$@\"";
          }
        ];
      };
    };
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

  #programs.fish.enable = true;
  programs.fish = {
    #defaultShell = true;
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
      # Manually packaging and enable a plugin
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

  #  programs.firefox = {
  #   enable = true;
  #profiles.default.settings = {
  #"widget.gtk.libadwaita-colors.enabled" = false;
  #"browser.theme.native-theme" = false;
  # };
  #  configPath = ".mozilla/firefox";
  #};
  programs.git = {
    enable = true;
    settings.user.name = "brokenpike";
    settings.user.email = "brokenpike@garmr.org";
    settings.credential.helper = "manager";
    settings.credential.credentialStore = "cache";
    signing.format = "openpgp";
  };
  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "24.05";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
