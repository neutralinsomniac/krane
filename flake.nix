{
  description = "NixOS on the Lenovo IdeaPad Duet Chromebook (MT8183 kukui-krane)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:neutralinsomniac/nixos-hardware/lenovo-ideapad-duet";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      ...
    }:
    let
      profile = "${nixos-hardware}/lenovo/ideapad/duet";

      # The patch series in this repository, rather than the copy
      # vendored into nixos-hardware: this tree is where it is developed.
      ubootPatches = map (name: ./u-boot + "/${name}") (
        nixpkgs.lib.naturalSort (builtins.attrNames (builtins.readDir ./u-boot))
      );

      packagesFor = pkgs: rec {
        uboot = (pkgs.callPackage "${profile}/u-boot.nix" { }).overrideAttrs (_: {
          patches = ubootPatches;
        });

        payload = pkgs.callPackage "${profile}/depthcharge-payload.nix" { inherit uboot; };

        krane-install-uboot = pkgs.callPackage "${profile}/uboot-installer.nix" { inherit payload; };

        default = payload;
      };

      # Build the payload from this tree's patches instead of the
      # vendored series.
      localPayload =
        { pkgs, ... }:
        {
          hardware.lenovo.ideapad.duet.uboot.package = (packagesFor pkgs).payload;
        };
    in
    {
      packages.aarch64-linux = (packagesFor nixpkgs.legacyPackages.aarch64-linux) // {
        installerImage = self.nixosConfigurations.installer.config.system.build.sdImage;
      };

      # Cross-built from x86_64: much faster than building on the device
      # itself, and enough for the bootloader bits.
      packages.x86_64-linux = packagesFor nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform;

      nixosModules = {
        default = self.nixosModules.krane;
        krane = {
          imports = [
            profile
            localPayload
          ];
        };
      };

      # A bootable installer image for the device:
      #   nix build .#installerImage
      nixosConfigurations.installer = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          "${profile}/sd-image-installer.nix"
          localPayload
          { system.stateVersion = "25.11"; }
        ];
      };

      # The system installed on the internal eMMC. Expects the partition
      # layout from the nixos-hardware README (depthcharge partition,
      # then an ESP labelled KRANE_ESP mounted at /boot, then an ext4
      # root labelled krane-nixos):
      #   nix build .#nixosConfigurations.duet.config.system.build.toplevel
      nixosConfigurations.duet = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          self.nixosModules.krane
          {
            networking.hostName = "duet";
            hardware.lenovo.ideapad.duet.uboot.enable = true;

            fileSystems."/" = {
              device = "/dev/disk/by-label/krane-nixos";
              fsType = "ext4";
            };
            fileSystems."/boot" = {
              device = "/dev/disk/by-label/KRANE_ESP";
              fsType = "vfat";
              options = [
                "fmask=0077"
                "dmask=0077"
              ];
            };

            networking.networkmanager.enable = true;
            services.openssh.enable = true;

            system.stateVersion = "25.11";
          }
        ];
      };
    };
}
