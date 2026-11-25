"""Silero TTS v5 (ru) speech networks rebuilt as plain PyTorch from the TorchScript in v5_ru.pt.

The TorchScript itself does not export to ONNX (hundreds of string branches from nn.MultiheadAttention's fast path),
so the same networks are written out here and the weights copied over; export.py proves the result sounds the same.
One utterance at a time (batch 1, no padding), so every key-padding mask is all-False and dropped.

Split for the phone:
  Encoder:  seq [1,T] int64, speaker [1] int64 -> log_dur [1,T], cond [1,T,128] (encoder + speaker + pitch)
  (Swift)   durations from log_dur (`durations`), frames = cond rows repeated (`expand`)
  Decoder:  frames [1,F,128] -> audio [1,S] at 48 kHz (hourglass decoder, mel, vocoder, ISTFT as matmuls)
  Homo:     the homograph BERT (padded rows, [HOMO]/[/HOMO] positions -> logit)
"""
import math
import torch
from torch import nn
import torch.nn.functional as F


def lin(src):
    l = nn.Linear(src.weight.shape[1], src.weight.shape[0], bias=src.bias is not None)
    l.weight.data.copy_(src.weight); l.bias.data.copy_(src.bias) if src.bias is not None else None
    return l


def conv(src):
    w = src.weight
    c = nn.Conv1d(w.shape[1] * src.groups, w.shape[0], w.shape[2], padding=src.padding[0], groups=src.groups,
                  bias=src.bias is not None)
    c.weight.data.copy_(w); c.bias.data.copy_(src.bias) if src.bias is not None else None
    return c


def ln(src):
    l = nn.LayerNorm(src.weight.shape[0], eps=src.eps)
    l.weight.data.copy_(src.weight); l.bias.data.copy_(src.bias)
    return l


def emb(src):
    e = nn.Embedding(*src.weight.shape)
    e.weight.data.copy_(src.weight)
    return e


def mods(lst):
    return [lst._modules[str(i)] for i in range(len(lst._modules))]


class PosEnc(nn.Module):
    def __init__(self, src):
        super().__init__()
        self.register_buffer("pe", src.pe.detach().clone()[:, 0, :])  # [5000, C]
        self.scale = nn.Parameter(src.scale.detach().clone())

    def forward(self, x):  # [B,T,C]
        return x + self.scale * self.pe[: x.shape[1]].unsqueeze(0)


class Attention(nn.Module):
    def __init__(self, src):
        super().__init__()
        self.h = src.num_heads
        self.in_proj = nn.Linear(src.in_proj_weight.shape[1], src.in_proj_weight.shape[0])
        self.in_proj.weight.data.copy_(src.in_proj_weight); self.in_proj.bias.data.copy_(src.in_proj_bias)
        self.out_proj = lin(src.out_proj)

    def forward(self, x):  # [B,T,C]
        b, t, c = x.shape
        q, k, v = self.in_proj(x).chunk(3, dim=-1)
        sh = lambda z: z.reshape(b, t, self.h, c // self.h).transpose(1, 2)
        q, k, v = sh(q), sh(k), sh(v)
        a = torch.softmax(q @ k.transpose(-1, -2) / math.sqrt(c // self.h), dim=-1)
        return self.out_proj((a @ v).transpose(1, 2).reshape(b, t, c))


class FFT(nn.Module):
    def __init__(self, src):
        super().__init__()
        assert not src.use_linear and not src.pitch_pred
        self.attn = Attention(src.self_attn)
        self.conv1, self.conv2 = conv(src.conv1), conv(src.conv2)
        self.norm1, self.norm2 = ln(src.norm1), ln(src.norm2)

    def forward(self, x):
        x = self.norm1(x + self.attn(x))
        y = x.transpose(1, 2)
        y = y + self.conv2(torch.relu(self.conv1(y)))
        return self.norm2(y.transpose(1, 2))


class Transformer(nn.Module):
    def __init__(self, src):
        super().__init__()
        self.pos = PosEnc(src.pos_encoder)
        self.layers = nn.ModuleList(FFT(l) for l in mods(src.layers))
        self.norm = ln(src.norm)

    def forward(self, x):
        x = self.pos(x)
        for l in self.layers:
            x = l(x)
        return self.norm(x)


class Predictor(nn.Module):  # TransformerSeriesPredictor, speaker_emb "pre"
    def __init__(self, src):
        super().__init__()
        self.emb, self.spk = emb(src.embedding), emb(src.speaker_embedding)
        self.tr = Transformer(src.transformer)
        self.lin = lin(src.lin)

    def forward(self, seq, speaker):
        x = self.emb(seq) + self.spk(speaker).unsqueeze(1)
        return self.lin(self.tr(x))  # [B,T,1]


class Encoder(nn.Module):
    def __init__(self, mm):
        super().__init__()
        t = mm.tacotron
        assert t.pitch_emb_type == "default" and t.pitch_strength == 1.0
        self.dur = Predictor(mm.dur_predictor.dur_pred)
        self.pitch = Predictor(mm.pitch_predictor.pitch_pred)
        self.emb, self.spk = emb(t.embedding), emb(t.speaker_embedding)
        self.enc = Transformer(t.encoder)
        self.pitch_proj = conv(t.pitch_proj)

    def forward(self, seq, speaker):
        log_dur = self.dur(seq, speaker).squeeze(-1)                      # [1,T]
        pitch = self.pitch(seq, speaker).transpose(1, 2)                  # [1,1,T]
        pitch = torch.where(pitch.abs() < 0.001, torch.zeros_like(pitch), pitch)  # update_pitch_coef at coef 1
        cond = self.enc(self.emb(seq)) + self.spk(speaker).unsqueeze(1)
        cond = cond + self.pitch_proj(pitch).transpose(1, 2)
        return log_dur, cond


class ConvNeXt(nn.Module):
    def __init__(self, src):
        super().__init__()
        self.dw, self.norm = conv(src.dwconv), ln(src.norm)
        self.pw1, self.pw2 = lin(src.pwconv1), lin(src.pwconv2)
        self.gamma = nn.Parameter(src.gamma.detach().clone())

    def forward(self, x):  # [B,C,F]
        y = self.norm(self.dw(x).transpose(1, 2))
        y = self.gamma * self.pw2(F.gelu(self.pw1(y)))
        return x + y.transpose(1, 2)


class Decoder(nn.Module):
    def __init__(self, mm):
        super().__init__()
        d = mm.tacotron.decoder
        self.sf = d.shorten_factor
        self.pos = PosEnc(d.pos_encoder)
        self.pre = FFT(mods(d.pre_vanilla_layers)[0])
        self.short1 = FFT(mods(d.shorten_layers)[1])  # layer 0's output is discarded in the original
        self.post = FFT(mods(d.post_vanilla_layers)[0])
        self.up = lin(d.upsample.proj); self.dim = d.upsample.dim
        self.norm = ln(d.norm)
        self.mel = lin(mm.tacotron.lin)
        b = mm.vocoder.backbone
        self.embed, self.vnorm = conv(b.embed), ln(b.norm)
        self.convnext = nn.ModuleList(ConvNeXt(c) for c in mods(b.convnext))
        self.final = ln(b.final_layer_norm)
        self.out = lin(mm.vocoder.head.out)

    def forward(self, frames):  # [1,F,128]
        L = frames.shape[1]
        x = self.pre(self.pos(frames))
        x = F.pad(x, (0, 0, 0, (-L) % self.sf))
        down = F.avg_pool1d(x.transpose(1, 2), self.sf, self.sf).transpose(1, 2)
        x = self.up(self.short1(down)).reshape(x.shape[0], -1, self.dim) + x
        x = self.norm(self.post(x[:, :L]))
        mel = self.mel(x).transpose(1, 2)                                # [1,192,F]
        v = self.vnorm(self.embed(mel).transpose(1, 2)).transpose(1, 2)
        for c in self.convnext:
            v = c(v)
        v = self.final(v.transpose(1, 2))
        mag, phase = self.out(v).transpose(1, 2).chunk(2, dim=1)
        return istft(torch.clamp(torch.exp(mag), max=100.0), phase)[None]


def istft(mag, phase, n=2400, hop=600):
    """The package's ISTFT ("same" padding, periodic Hann) for one utterance, as plain matmuls so ONNX needs no DFT op:
    irfft by its definition (imaginary parts of DC and Nyquist ignored), then overlap-add of 4 shifted hops."""
    re, im = (mag * torch.cos(phase))[0], (mag * torch.sin(phase))[0]          # [n/2+1, F]
    k = torch.arange(n // 2 + 1).unsqueeze(1); t = torch.arange(n).unsqueeze(0)
    ang = (k * t % n).float() * (2 * math.pi / n)                              # exact angle, no float drift
    wk = torch.full((n // 2 + 1, 1), 2.0); wk[0] = 1.0; wk[-1] = 1.0
    frames = ((wk * re).T @ torch.cos(ang) - (wk * im).T @ torch.sin(ang)) / n  # [F, n]
    win = 0.5 - 0.5 * torch.cos(torch.arange(n).float() * (2 * math.pi / n))
    q = n // hop
    def ola(fr):                                                               # [F, n] -> [(F+q-1)*hop]
        parts = fr.reshape(fr.shape[0], q, hop)
        return sum(F.pad(parts[:, i], (0, 0, i, q - 1 - i)) for i in range(q)).reshape(-1)
    y = ola(frames * win)
    env = ola((win * win).expand(frames.shape[0], n))
    pad = (n - hop) // 2
    return y[pad:-pad] / env[pad:-pad]


def durations(log_dur):
    """The original's duration post-processing for one plain sentence (no SSML, rate 1)."""
    d = torch.round(torch.clamp(torch.exp(log_dur) - 1, min=0))
    d[0, 0] = min(d[0, 0], 5); d[0, -1] = min(d[0, -1], 7); d[0, -2] = 13; d[0, -3] = min(d[0, -3], 13)
    return d


def expand(cond, d):
    return torch.repeat_interleave(cond[0], d[0].long(), dim=0).unsqueeze(0)


# ---- Homograph solver (TinyBERT, 3 layers, 312 wide, 12 heads) ----

class BertLayer(nn.Module):
    def __init__(self, src):
        super().__init__()
        s = src.attention.self
        self.h, self.d = s.num_attention_heads, s.attention_head_size
        self.q, self.k, self.v = lin(s.query), lin(s.key), lin(s.value)
        self.ao, self.aln = lin(src.attention.output.dense), ln(src.attention.output.LayerNorm)
        self.i, self.o, self.oln = lin(src.intermediate.dense), lin(src.output.dense), ln(src.output.LayerNorm)

    def forward(self, x):  # [N,L,312]; no attention mask, as in the original (padding is attended too)
        n, l, c = x.shape
        sh = lambda z: z.reshape(n, l, self.h, self.d).transpose(1, 2)
        a = torch.softmax(sh(self.q(x)) @ sh(self.k(x)).transpose(-1, -2) / math.sqrt(self.d), dim=-1)
        ctx = (a @ sh(self.v(x))).transpose(1, 2).reshape(n, l, c)
        x = self.aln(self.ao(ctx) + x)
        return self.oln(self.o(F.gelu(self.i(x))) + x)


class Homo(nn.Module):
    """input_ids [N,L] (padded with 0, all attended), start [N], end [N] -> logit [N] (sorted variant 1 vs 0)"""
    def __init__(self, src):
        super().__init__()
        b = src.bert
        e = b.embeddings
        self.register_buffer("word_q", e.word_embeddings.weight.detach().clone().to(torch.int8))
        self.scale, self.zp = float(b.scale), float(b.zero_point)
        self.pos, self.tok = e.position_embeddings.weight.detach().clone(), e.token_type_embeddings.weight.detach().clone()[0]
        self.pos = nn.Parameter(self.pos); self.tok = nn.Parameter(self.tok)
        self.eln = ln(e.LayerNorm)
        self.layers = nn.ModuleList(BertLayer(l) for l in mods(b.encoder.layer))
        c = list(src.homo_clf._modules.values())
        self.c1, self.c2 = lin(c[0]), lin(c[3])

    def forward(self, input_ids, start, end):
        n, l = input_ids.shape
        w = self.scale * (self.word_q[input_ids].float() - self.zp)
        x = self.eln(w + self.pos[:l].unsqueeze(0) + self.tok)
        for layer in self.layers:
            x = layer(x)
        marker = x[torch.arange(n), start]                                      # [N,312]
        p = torch.arange(l).unsqueeze(0)
        m = ((p > start.unsqueeze(1)) & (p < end.unsqueeze(1))).float().unsqueeze(-1)
        word = (x * m).sum(1) / m.sum(1)
        return self.c2(torch.relu(self.c1(torch.cat([marker, word], dim=-1)))).squeeze(-1)
