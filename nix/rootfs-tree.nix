# The non-store part of the rootfs (/etc, /bin/sh, profile links, dirs).
# Built with the *target* package set so every embedded store path is aarch64.
{ pkgs, lab-env }:
let
  etc = ../rootfs/etc;
in
pkgs.runCommand "flip4-rootfs-tree" { } ''
  r=$out
  mkdir -p $r/{bin,usr/bin,etc/nix,etc/ssh,etc/ssl/certs,root/.ssh,tmp,run,var/empty,var/log,proc,sys,dev,mnt/sdcard,data,home,nix/var/nix/profiles,nix/var/nix/gcroots,nix/var/nix/db}
  chmod 1777 $r/tmp
  chmod 0700 $r/root $r/root/.ssh
  chmod 0755 $r/var/empty

  # Real files (not store symlinks) so they can be edited in place on the phone.
  for f in passwd group shells hosts nsswitch.conf profile bashrc; do
    install -m644 ${etc}/$f $r/etc/$f
  done
  install -m644 ${etc}/nix.conf     $r/etc/nix/nix.conf
  install -m644 ${etc}/sshd_config  $r/etc/ssh/sshd_config
  install -m644 ${etc}/root-bashrc  $r/root/.bashrc
  install -m644 ${etc}/root-profile $r/root/.profile

  # Profile generation 1 -> lab-env. /nix/var/nix/profiles is a GC root dir,
  # so `nix-collect-garbage` inside the chroot won't eat the toolset.
  ln -s ${lab-env} $r/nix/var/nix/profiles/default-1-link
  ln -s default-1-link $r/nix/var/nix/profiles/default
  ln -s /nix/var/nix/profiles/default $r/root/.nix-profile

  P=/nix/var/nix/profiles/default
  ln -s $P/bin/bash $r/bin/bash
  ln -s $P/bin/bash $r/bin/sh
  ln -s $P/bin/env  $r/usr/bin/env
  ln -s $P/etc/ssl/certs/ca-bundle.crt $r/etc/ssl/certs/ca-certificates.crt
  ln -s ca-certificates.crt $r/etc/ssl/certs/ca-bundle.crt

  # Written at boot by the KernelSU module (Android has no resolv.conf).
  echo "nameserver 1.1.1.1" > $r/etc/resolv.conf
  echo flip4-lab > $r/etc/hostname
''
