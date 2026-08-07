# ML RTL Implementation Order

Recommended RTL sequence:

1. Testbench reference models and self-checkers
2. Standalone MAC RTL block
3. Dot-product control around MAC
4. Packed vector lane support (int8/int16)
5. Horizontal reduction path
6. Matrix-tile controller

Bring-up checkpoints:

- MAC unit test
- Dot-product test
- Packed-lane test
- Reduction test
- Matrix-tile test

Rule: keep base CPU RTL stable while adding ML blocks.

