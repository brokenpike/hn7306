# GNOME desktop session. The login screen (GDM) is set up in configuration.nix.
_:

{
  services.desktopManager.gnome = {
    enable = true;

    # Fractional scaling and native XWayland scaling.
    extraGSettingsOverrides = ''
      [org.gnome.mutter]
      experimental-features=['scale-monitor-framebuffer', 'xwayland-native-scaling']
    '';
  };
}
