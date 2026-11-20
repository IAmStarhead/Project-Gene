# Training sword

- **Sword**, from *LowPoly Medieval Weapons*, by Quaternius.
- Original pack and CC0 license: https://opengameart.org/content/lowpoly-medieval-weapons
- Binary conversion used here: https://github.com/nrknithin/html-anime/tree/55abf74e37d9b5a62e9f99428a5f7aad8e7ed822/models/library/sword
  (source FBX and pack hashes recorded in `meta.json` there).
- Original converted GLB SHA-256: `bd0cbe3865442de70ebf2f86b15c34c1f10af0136e2edf6fd64961dfcf0720f2`.
- This copy: `f8f99fba1e38af7bcc633c8b61de4060bc5009a8b15cacd2bb97a0fa98b1cf47`.
- Changes: decoded meshopt and dequantized for Godot import using glTF-Transform;
  changed the five material alpha modes to opaque and base alpha to 1 (the
  converted model used alpha mask with zero alpha, invisible in Godot).
  Geometry, colours and authored shape otherwise follow that converted GLB.

CC0 1.0: https://creativecommons.org/publicdomain/zero/1.0/
