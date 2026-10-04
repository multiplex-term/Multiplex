# RNNoise (vendored)

Upstream: https://github.com/xiph/rnnoise at
`70f1d256acd4b34a572f999a05c87bf00b67730d` (BSD-3-Clause, `COPYING`).

What is here:

- `Sources/CRNNoise/` — the library sources from upstream `src/` (no
  training tools, no x86 runtime-dispatch `.c` files) and `include/rnnoise.h`.
- `rnnoise_data.h` and the `init_rnnoise` half of `rnnoise_data.c` come from
  the model archive
  `rnnoise_data-0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37.tar.gz`
  (both are identical for the regular and little models). The archive's
  weight tables are 78 MB of C source and are deliberately absent.

Built with `USE_WEIGHTS_FILE`: `rnnoise_create` needs a model from
`rnnoise_model_from_buffer`. The app downloads upstream's model archive on
request (Settings → Voice Input), checks it against upstream's SHA-256,
converts the regular model's tables into the blob `dump_weights_blob` would
write, checks that blob's SHA-256 too, and loads it
(`RNNoiseModelSource`, `RNNoiseModelStore`, `AudioDenoiser`).

Local patches (keep when bumping):

- `denoise.c` `rnnoise_model_from_buffer`: initialize `model->file = NULL`
  (upstream leaves it uninitialized and `rnnoise_model_free` `fclose`s it).

Bumping: replace the sources from a new upstream checkout, re-take
`rnnoise_data.h` + `init_rnnoise` from the matching model archive, and update
the archive URL and both pinned hashes in `RNNoiseModelSource`.
