# Third-party notices

Prism is licensed under the GNU General Public License v3.0 (see `LICENSE`). It includes or builds on the following work.

## mlx-audio-separator

The BS-Roformer model code and the checkpoint key mapping in `Packages/StemSeparation` are ported from mlx-audio-separator's MLX implementation: https://github.com/ssmall256/mlx-audio-separator

```
MIT License

Copyright (c) 2024-2026 ssmall256

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## MLX Swift

Prism runs the model with MLX Swift (MIT, Apple), fetched by Swift Package Manager: https://github.com/ml-explore/mlx-swift

## BS-RoFormer

Band-Split RoFormer is described in *Music Source Separation with Band-Split RoPE Transformer* (Wei-Tsung Lu, Ju-Chiang Wang, Qiuqiang Kong, Yun-Ning Hung, 2023).

## Model weights

Prism doesn't include any model weights. On first run it downloads the BS-Roformer SW checkpoint (six stems) from python-audio-separator's public model release (https://github.com/nomadkaraoke/python-audio-separator), checks its SHA-256 and converts it on your Mac. The weights are not covered by Prism's licence.
