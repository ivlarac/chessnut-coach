#!/usr/bin/env python3
"""Rebuild the bundled Maia3-5M Core ML policy from its preferred checkpoint.

The vendored Maia source and model checkpoint remain AGPL-3.0-only. This script
only adapts RMSNorm into Core ML-convertible primitive operations; it does not
change the learned parameters or move-policy semantics.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path
from types import SimpleNamespace

import coremltools as ct
import torch
from torch import nn


EXPECTED_CHECKPOINT_SHA256 = "ba14208b2992d85502f5fb501934abf6aaaeb355e9f3fdf90e326911f562524f"


class PrimitiveRMSNorm(nn.Module):
    def __init__(self, source: nn.RMSNorm):
        super().__init__()
        self.weight = nn.Parameter(source.weight.detach().clone())
        self.eps = source.eps if source.eps is not None else torch.finfo(source.weight.dtype).eps

    def forward(self, value: torch.Tensor) -> torch.Tensor:
        variance = value.pow(2).mean(dim=-1, keepdim=True)
        return value * torch.rsqrt(variance + self.eps) * self.weight


def replace_rms_norms(module: nn.Module) -> None:
    for name, child in list(module.named_children()):
        if isinstance(child, nn.RMSNorm):
            setattr(module, name, PrimitiveRMSNorm(child))
        else:
            replace_rms_norms(child)


class PolicyOnly(nn.Module):
    def __init__(self, model: nn.Module):
        super().__init__()
        self.model = model

    def forward(
        self,
        board_history: torch.Tensor,
        self_rating: torch.Tensor,
        opponent_rating: torch.Tensor,
    ) -> torch.Tensor:
        move_logits, _, _ = self.model(board_history, self_rating, opponent_rating)
        return move_logits


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def model_configuration() -> SimpleNamespace:
    return SimpleNamespace(
        history=8,
        use_padding=True,
        include_time_info=False,
        dim_emb=128,
        num_blocks=8,
        mlp_ratio=2.0,
        dropout=0.0,
        use_gab=True,
        use_relative_bias=False,
        use_absolute_pe=False,
        use_rms_norm=True,
        omit_qkv_biases=True,
        activation="gelu",
        dim_vit=256,
        head_hid_dim=256,
        num_heads=8,
        gab_gen_size=64,
        gab_per_square_dim=0,
        gab_intermediate_dim=64,
    )


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--maia-source",
        type=Path,
        default=root / "Vendor/Maia3/source",
    )
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=root / "Vendor/Maia3/source/maia3-5m.pt",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=root / "ChessnutCoach/Models/Maia3_5M.mlpackage",
    )
    args = parser.parse_args()

    actual_hash = sha256(args.checkpoint)
    if actual_hash != EXPECTED_CHECKPOINT_SHA256:
        raise RuntimeError(
            f"unexpected Maia3-5M checkpoint SHA-256: {actual_hash}"
        )

    sys.path.insert(0, str(args.maia_source))
    from maia3.models import MAIA3Model

    model = MAIA3Model(model_configuration())
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    state_dict = checkpoint.get("model_state_dict", checkpoint)
    state_dict = {
        key.replace("smolgen", "gab"): value
        for key, value in state_dict.items()
    }
    missing, unexpected = model.load_state_dict(state_dict, strict=False)
    if missing or unexpected:
        raise RuntimeError(
            f"checkpoint mismatch: missing={missing}, unexpected={unexpected}"
        )

    model.eval()
    replace_rms_norms(model)
    wrapper = PolicyOnly(model).eval()
    example = (
        torch.zeros((1, 64, 96), dtype=torch.float32),
        torch.tensor([800.0], dtype=torch.float32),
        torch.tensor([800.0], dtype=torch.float32),
    )

    with torch.no_grad():
        eager_output = wrapper(*example)
    exported = torch.export.export(wrapper, example, strict=False).run_decompositions({})
    with torch.no_grad():
        exported_output = exported.module()(*example)
    torch.testing.assert_close(eager_output, exported_output, rtol=0, atol=0)

    converted = ct.convert(
        exported,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        outputs=[ct.TensorType(name="move_logits")],
    )
    converted.author = (
        "University of Toronto CSSLab; Core ML conversion by Chessnut Coach contributors"
    )
    converted.license = "GNU Affero General Public License v3.0 only"
    converted.short_description = "Maia3-5M human-like chess move policy"
    converted.version = "b6559de2398d7140b985f28fd2c19fb5e47ddabe"
    converted.save(str(args.output))
    print(f"saved {args.output}")


if __name__ == "__main__":
    main()
