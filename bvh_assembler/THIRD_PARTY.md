# Third-party dependencies

This tool builds on two single-header C++ libraries that are **not** included
in this repository (they were removed to avoid re-distributing someone else's
code as this project's own). Download them into this directory before
building:

- **tiny_bvh.h** — BVH construction/traversal, by Jacco Bikker (MIT License).
  https://github.com/jbikker/tinybvh
- **tiny_obj_loader.h** — Wavefront OBJ parsing, by Syoyo Fujita and
  contributors (MIT License).
  https://github.com/tinyobjloader/tinyobjloader

Place both headers directly in `bvh_assembler/` (same folder as
`main.cpp`). They're already listed in `.gitignore` so they won't be
accidentally re-committed.

All other files in this directory (`main.cpp`, `obj_loader.cpp/h`,
`bvh_builder.cpp/h`, `third_party.cpp`, the `.py` scripts) are original code
written for this project.
