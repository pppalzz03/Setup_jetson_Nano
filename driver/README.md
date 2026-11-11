# driver/

Put the SENSING driver package here, extracted, with this exact folder name:

```
driver/SG4A_NONX_G2Y_A1_ORIN_NANO_YUV_JP6.2_L4TR36.4.3/
├── install.sh  quick_bring_up.sh  clock_config.sh  camera_fsync_set.sh  Readme.md
├── boot/   (Image, overlay .dtbo ...)
├── dtb/
└── ko/     (max96712.ko, sgx-yuv-gmsl2.ko, tegra-camera.ko, nvhost-nvcsi-t194.ko ...)
```

Binary files in this folder are stored with **Git LFS** (see `../.gitattributes`); `*.sh`, `*.md`, `*.txt` stay normal text.

The scripts look for the package here first, then in `~/SG4A_NONX_G2Y_A1_ORIN_NANO_YUV_JP6.2_L4TR36.4.3`, or use `--pkg DIR`.

If the scripts report *"Git LFS pointer files"*, the binaries were not downloaded:

```bash
sudo apt install git-lfs
git lfs install
git lfs pull
```

Keep the repository **private**: the package is SENSING's software, check its license before publishing it.
