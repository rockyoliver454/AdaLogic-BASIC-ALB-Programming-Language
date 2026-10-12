#!/usr/bin/env python3
"""Train a sequence cartridge (.albm type 4) for the ternary engine.

The forward pass (post Path E) is a deterministic successor-of-match rule:
the attention window holds the last <=64 tokens BEFORE the current one,
the argmin L1 embedding distance picks a predecessor position, and the
prediction is the token that followed it. The only parameters touching
the output are the 256x256 signed-byte embeddings, so training them IS
training the model.

Embedding structure (closed form, three backoff tiers):
    E(t)[j] = -64 + A*[j == t] + B*[j == C1(t)] + D*[j == C2(t)]
  t       - exact token identity dim      (most-recent bigram)
  C1(t)   - learned attractor class dim   (class recency)
  C2(t)   - coarser attractor class dim   (deep fallback)
  else    - every present token ties, most recent wins -> echo

C1/C2 are pointers into token space, optimised by coordinate descent with
an exact one-pass statistic: for query t absent from the window, the
tier-1 winner would be the most recent member of attractor C1(t) -- so
each candidate c is scored by whether x[last_ptr1[c] + 1] == x[i+1].

Outputs:
    models/alb_seq.albm           - v1 cartridge, Model_Type 4
    models/alb_seq_metrics.json   - train/dev/test accuracy + baselines
    src/model/seq_golden.ads      - frozen probe vectors for seq_battery
"""

import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
ALB_ROOT = Path(r"H:\GNATSTUDIO\bin\AdaLogic_BASIC")
MANIFEST = ROOT / "data" / "alb" / "corpus_manifest.jsonl"
OUT_MODEL = ROOT / "models" / "alb_seq.albm"
OUT_METRICS = ROOT / "models" / "alb_seq_metrics.json"
OUT_GOLDEN = ROOT / "src" / "model" / "seq_golden.ads"

VOCAB = 256          # byte-level vocabulary
FEAT = 256           # Feature_Dim
HID = 256            # Hidden_Dim
CTX = 4096           # Context_Cap
SEQ = 128            # Seq_Dim attention window
EMAG = 64            # Embedding_Magnitude
MAX_TEXT = 12
VOCAB_STRIDE = 1 + MAX_TEXT + 2

MAX_TRAIN_BYTES = 1_400_000
MAX_EVAL_BYTES = 600_000
OPT_STRIDE = 3       # subsample positions during coordinate descent
ROUNDS = 3
EVAL_STRIDE = 4      # subsample for blended-head evaluation

MAX_DIST = FEAT * 2 * EMAG   # mirrors Inference_Graph.Max_Dist

PROBE = b'MODULE SeqProbe\nPROCEDURE Main()\nBEGIN\n  PRINT "SEQ"\nEND Main\nENDMODULE SeqProbe\n'


def tern(v):
    """The frozen mod-3 cycle from inference_graph: 0->+1, 1->-1, 2->0."""
    m = v % 3
    return 1 if m == 0 else (-1 if m == 1 else 0)


def load_split(split, cap):
    """Concatenate manifest files for a split in manifest order."""
    data = bytearray()
    with open(MANIFEST, "r", encoding="utf-8") as f:
        for line in f:
            rec = json.loads(line)
            if rec.get("split") != split:
                continue
            path = ALB_ROOT / rec["path"]
            try:
                data += path.read_bytes() + b"\n\n"
            except OSError:
                continue
            if len(data) >= cap:
                break
    return bytes(data[:cap])


def make_dist(C1, C2, A, B, D):
    """Closed-form L1 between structured embeddings.

    E(t)[j] = -64 + A*[j==t] + B*[j==C1(t)] + D*[j==C2(t)].
    Only the <=6 dims in {t, u, C1(t), C1(u), C2(t), C2(u)} can differ.
    """
    def dist(t, u):
        total = 0
        # Set dedupe: coincident pointer dims count once, like a vector L1.
        for j in {t, u, C1[t], C1[u], C2[t], C2[u]}:
            dt = (A if j == t else 0) + (B if j == C1[t] else 0) \
                 + (D if j == C2[t] else 0)
            du = (A if j == u else 0) + (B if j == C1[u] else 0) \
                 + (D if j == C2[u] else 0)
            d = dt - du
            total += d if d >= 0 else -d
        return total

    return [[dist(t, u) for u in range(VOCAB)] for t in range(VOCAB)]


def evaluate(data, D):
    """Exact mirror of Forward_Core's prediction path.

    At step i the ring already holds x[i-1], x[i-2], ...; the window keys
    are the last min(count, 64) of them. Argmin distance wins, earliest
    offset (most recent) wins ties, and the prediction is the successor of
    the matched token. Empty window echoes the input.
    """
    last = {}            # token -> most recent position
    hits = 0
    npos = 0
    for i in range(len(data) - 1):
        t = data[i]
        cutoff = i - SEQ
        best_pos = -1
        if t in last and last[t] >= cutoff:
            best_pos = last[t]            # dist 0 group = {t}
        else:
            best_d = -1
            for u, pos in last.items():
                if pos < cutoff:          # fell out of the window
                    continue
                d = D[t][u]
                if best_d < 0 or d < best_d or (d == best_d and pos > best_pos):
                    best_d = d
                    best_pos = pos
        if best_pos < 0:
            pred = t                      # empty window -> echo
        else:
            pred = data[best_pos + 1]     # successor of the match
        if pred == data[i + 1]:
            hits += 1
        npos += 1
        last[t] = i
    return hits / npos if npos else 0.0, hits, npos


def dominant_successor_baseline(data, succ_star):
    hits = sum(1 for i in range(len(data) - 1)
               if succ_star[data[i]] == data[i + 1])
    n = max(1, len(data) - 1)
    return hits / n


def stats_pass(data, C1, C2, tier):
    """Score candidate attractors for `tier` (1 or 2) in one corpus pass.

    tier 1: applies when query token t is absent from the window.
            winner = most recent u with C1(u) == c.
    tier 2: applies when t absent AND no C1(u) == C1(t) member present.
            winner = most recent u with C2(u) == c.
    """
    scores = [dict() for _ in range(VOCAB)]
    opps = [0] * VOCAB
    last_tok = {}
    last_p1 = {}
    last_p2 = {}
    for i in range(0, len(data) - 1, OPT_STRIDE):
        t = data[i]
        cutoff = i - SEQ
        t_present = last_tok.get(t, -10**9) >= cutoff
        if not t_present:
            p1_hit = last_p1.get(C1[t], -10**9) >= cutoff
            if tier == 1:
                for c, lp in last_p1.items():
                    if lp >= cutoff:
                        scores[t][c] = scores[t].get(c, 0) + \
                            (1 if data[lp + 1] == data[i + 1] else 0)
                opps[t] += 1
            elif not p1_hit:
                for c, lp in last_p2.items():
                    if lp >= cutoff:
                        scores[t][c] = scores[t].get(c, 0) + \
                            (1 if data[lp + 1] == data[i + 1] else 0)
                opps[t] += 1
        last_tok[t] = i
        last_p1[C1[t]] = i
        last_p2[C2[t]] = i
    return scores, opps


def refine(C1, C2, tier, scores):
    """Assign each token the argmax-score attractor (ties keep current)."""
    changed = 0
    tgt = C1 if tier == 1 else C2
    for t in range(VOCAB):
        if not scores[t]:
            continue
        best_c = max(sorted(scores[t]), key=lambda c: scores[t][c])
        if scores[t][best_c] > 0 and best_c != tgt[t]:
            tgt[t] = best_c
            changed += 1
    return changed


# --- Path E.2: bigram-backoff readout head ---------------------------------
#
# The trained cartridge ships A_W = 0, B_W = 0, Gate_W = 1s, so the SSM
# fold contributes nothing and the gate blend leaves the hidden state a
# pure current-token fingerprint:  h = P . E(x_t).  The engine's head
# then scores  argmax_v  E(v) . h = Bhat[v][x_t]  -- literally a learned
# bigram table through the ternary sandwich E.P.E^T.  It fires only when
# the attention match is fuzzy (Min_Dist > Head_Gate), i.e. exactly where
# the successor readout is weakest.
#
# Training: structured perceptron. score(v) = s_v' P s_x with spike
# vectors s_t over dims {t, C1(t), C2(t)}, so every correction is the
# rank-1 update  P += s_y (x) s_x^T - s_pred (x) s_x^T.  The float
# accumulator is quantised to ternary at a swept threshold, then polished
# by greedy single-cell hill-climbing on fire-region positions.

def mirror_state(data, stride=1):
    """Exact mirror of the engine's attention + pair-match stages.

    Returns (min_d, next_byte, succ_pred, pair_d, pair_succ, x_t) at
    every stride-th position. min_d is None on an empty window (engine
    echoes the input then). pair_d is None when the window holds fewer
    than two live tokens (engine skips the pair scan). The hidden-state
    head needs no mirror: with A_W = 0 its prediction is
    argmax_v Bhat[v][x_t] -- a table lookup.
    """
    last = {}
    recs = []
    for i in range(len(data) - 1):
        t = data[i]
        # --- attention match over the pre-push window ---
        cutoff = i - SEQ
        if t in last and last[t] >= cutoff:
            best_pos, min_d = last[t], 0
        else:
            best_pos, best_d = -1, -1
            for u, pos in last.items():
                if pos < cutoff:
                    continue
                d = D_CACHE[t][u]
                if best_d < 0 or d < best_d or (d == best_d and pos > best_pos):
                    best_d, best_pos = d, pos
            min_d = best_d if best_d >= 0 else MAX_DIST
        succ = data[best_pos + 1] if best_pos >= 0 else t
        # --- pair match: anchor offset O in [0, VC-2] with
        #     VC = min(count, SEQ); in positions: p = i-1-O down to
        #     lo = max(1, i - min(i,SEQ) + 1). Most recent wins ties. ---
        pair_d = pair_succ = None
        if i >= 2:
            lo = max(1, i - min(i, SEQ) + 1)
            prev = data[i - 1]
            for p in range(i - 1, lo - 1, -1):
                d = D_CACHE[prev][data[p - 1]] + D_CACHE[t][data[p]]
                if pair_d is None or d < pair_d:
                    pair_d, pair_succ = d, data[p + 1]
                    if d == 0:
                        break
        if i % stride == 0:
            recs.append((min_d if best_pos >= 0 else None,
                         data[i + 1], succ, pair_d, pair_succ, t))
        last[t] = i
    return recs


def spike_mat(C1, C2, A, B, D):
    """Sparse spike vectors s_t over dims {t, C1(t), C2(t)} with
    coefficients {A, B, D} -- E(t) = -64 + s_t."""
    S = np.zeros((VOCAB, FEAT))
    for v in range(VOCAB):
        S[v, v] += A
        S[v, C1[v]] += B
        S[v, C2[v]] += D
    return S


def train_head_P(S, xs, ys):
    """Structured perceptron float accumulator over sampled pairs."""
    Pf = np.zeros((FEAT, FEAT), dtype=np.float64)
    for x, y in zip(xs, ys):
        sxv = S[x]
        pred = int((S @ (Pf @ sxv)).argmax())
        if pred != y:
            Pf += np.outer(S[y] - S[pred], sxv)
    return Pf


def quantise_P(Pf, tau):
    P = np.zeros((FEAT, FEAT), dtype=np.int8)
    lim = np.abs(Pf).max() * tau
    P[Pf >= lim] = 1
    P[Pf <= -lim] = -1
    return P


def head_preds(xs, E_int, P):
    """argmax_v E(v) . P . E(x) for an array of input bytes."""
    Bhat = np.asarray(E_int, dtype=np.int64) @ np.asarray(P, dtype=np.int64) \
        @ np.asarray(E_int, dtype=np.int64).T
    return Bhat[:, np.asarray(xs, dtype=np.int64)].argmax(axis=0)


def hillclimb_P(P, E_int, fire_x, fire_y, iters=6, cells_per_iter=3000):
    """Greedy single-cell flips scored by head accuracy on fire-region
    samples. A flip (a,b) += delta changes Bhat[v][x] by
    delta * E[v][a] * E[x][b] -- an incremental score-matrix update."""
    Ei = np.asarray(E_int, dtype=np.int64)
    Bhat = Ei @ P.astype(np.int64) @ Ei.T
    scores = Bhat[:, fire_x].T.copy()
    fy = np.asarray(fire_y, dtype=np.int64)
    cur = float(np.mean(scores.argmax(axis=1) == fy))
    rng = np.random.RandomState(0)
    for _ in range(iters):
        improved = False
        cells = rng.randint(0, FEAT, (2, cells_per_iter))
        for k in range(cells.shape[1]):
            a, b = int(cells[0, k]), int(cells[1, k])
            old = int(P[a, b])
            for nv in ((1, -1) if old == 0 else ((-1, 0) if old == 1
                                                 else (0, 1))):
                upd = np.outer((nv - old) * Ei[:, a],
                               Ei[fire_x, b]).T
                scores += upd
                acc = float(np.mean(scores.argmax(axis=1) == fy))
                if acc > cur + 1e-7:
                    cur, P[a, b], improved = acc, nv, True
                    break
                scores -= upd
        if not improved:
            break
    return P, cur


def pack_ternary(values):
    """u32 length frame + 2-bit lanes, lane 0 = top bits. 0->0, 1->1, -1->2."""
    n = len(values)
    out = bytearray()
    nbytes = (n + 3) // 4
    out += nbytes.to_bytes(4, "little")
    for b in range(nbytes):
        byte = 0
        for lane in range(4):
            k = b * 4 + lane
            if k < n:
                code = 0 if values[k] == 0 else (1 if values[k] == 1 else 2)
                byte |= code << (2 * (3 - lane))
        out.append(byte)
    return out


def serialize(embeddings, proj_w, a_w=None, b_w=None, g_w=None):
    """Emit a v1 .albm blob (type 4) mirroring Albm_Model.Serialize.

    a_w/b_w/g_w default to the builtin patterns; the trained cartridge
    overrides them with the shift-register delay line.
    """
    buf = bytearray()
    buf += b"ALBT"
    buf += (1).to_bytes(2, "little")      # version
    buf += (4).to_bytes(2, "little")      # model type: trained seq
    buf += (1).to_bytes(4, "little")      # layers
    buf += FEAT.to_bytes(4, "little")
    buf += HID.to_bytes(4, "little")
    buf += CTX.to_bytes(4, "little")
    buf += (0).to_bytes(2, "little")      # checksum alg (reserved)

    buf += VOCAB.to_bytes(4, "little")    # vocab rows
    for i in range(VOCAB):
        text = b"?" if i == 0 else bytes([i])
        text = text + b" " * (MAX_TEXT - len(text))
        buf += bytes([1]) + text + i.to_bytes(2, "little")

    if a_w is None:
        a_w = [-tern(j) for i in range(HID) for j in range(1, HID + 1)]
    if b_w is None:
        b_w = [tern(i) for i in range(1, HID + 1)]
    if g_w is None:
        g_w = [tern(i - 1) for i in range(1, HID + 1)]
    p_w = [int(proj_w[i][j]) for i in range(HID) for j in range(FEAT)]
    buf += pack_ternary(a_w)
    buf += pack_ternary(b_w)
    buf += pack_ternary(g_w)
    buf += pack_ternary(p_w)

    buf += (VOCAB * FEAT).to_bytes(4, "little")
    for t in range(VOCAB):
        for j in range(FEAT):
            v = embeddings[t][j]
            buf.append((v + 256) % 256)

    buf += b"\x00" * 4                    # footer
    return bytes(buf)


def build_embeddings(C1, C2, A, B, D):
    emb = [[-EMAG] * FEAT for _ in range(VOCAB)]
    for t in range(VOCAB):
        emb[t][t] += A
        emb[t][C1[t]] += B
        emb[t][C2[t]] += D
    for t in range(VOCAB):
        for j in range(FEAT):
            assert -EMAG <= emb[t][j] <= EMAG, (t, j, emb[t][j])
    return emb


def main():
    train = load_split("train", MAX_TRAIN_BYTES)
    dev = load_split("dev", MAX_EVAL_BYTES)
    test = load_split("test", MAX_EVAL_BYTES)
    print(f"corpus bytes: train={len(train)} dev={len(dev)} test={len(test)}")

    # Baseline 1: dominant successor lookup (no window).
    succ_cnt = [dict() for _ in range(VOCAB)]
    for i in range(len(train) - 1):
        succ_cnt[train[i]][train[i + 1]] = \
            succ_cnt[train[i]].get(train[i + 1], 0) + 1
    succ_star = [max(sorted(succ_cnt[t]),
                     key=lambda s: succ_cnt[t][s], default=t)
                 for t in range(VOCAB)]
    base_dom = dominant_successor_baseline(test, succ_star)

    # Baseline 2: identity embeddings -> pure most-recent bigram.
    C1 = list(range(VOCAB))
    C2 = list(range(VOCAB))
    D_id = make_dist(C1, C2, 128, 0, 0)
    base_id_train, _, _ = evaluate(train[:MAX_EVAL_BYTES], D_id)
    base_id_test, _, _ = evaluate(test, D_id)

    # Init: attractor = dominant successor (continuation pointer).
    C1 = [succ_star[t] for t in range(VOCAB)]
    C2 = [succ_star[succ_star[t]] for t in range(VOCAB)]

    best = None
    for rnd in range(ROUNDS):
        s1, _ = stats_pass(train, C1, C2, tier=1)
        refine(C1, C2, 1, s1)
        s2, _ = stats_pass(train, C1, C2, tier=2)
        refine(C1, C2, 2, s2)
        for (a, b, d) in ((96, 32, 0), (64, 64, 0), (64, 40, 24),
                          (80, 32, 16), (48, 48, 32), (128, 0, 0)):
            acc, hits, npos = evaluate(
                train[:MAX_EVAL_BYTES // OPT_STRIDE],
                make_dist(C1, C2, a, b, d))
            if best is None or acc > best[0]:
                best = (acc, a, b, d)
        print(f"round {rnd + 1}: best sampled train acc={best[0]:.4f} "
              f"(A,B,D)={best[1:]}")
    acc, A, B, D = best

    D_tab = make_dist(C1, C2, A, B, D)
    tr_acc, tr_h, tr_n = evaluate(train[:MAX_EVAL_BYTES], D_tab)
    dev_acc, dev_h, dev_n = evaluate(dev, D_tab)
    tst_acc, tst_h, tst_n = evaluate(test, D_tab)

    emb = build_embeddings(C1, C2, A, B, D)

    # --- Path E.2: bigram-backoff readout head ----------------------------
    # A_W = 0, B_W = 0, Gate_W = 1s -> h = P.E(x_t), and the head score
    # E(v).h = Bhat[v][x_t] is a learned transition table consulted when
    # the attention match is fuzzy (Min_Dist > Head_Gate).
    global D_CACHE
    D_CACHE = D_tab
    HEAD_GATE = 64                    # must match Head_Gate in the engine
    PAIR_GATE = 0                     # must match Pair_Gate in the engine
    S = spike_mat(C1, C2, A, B, D)
    tr_state = train[:MAX_EVAL_BYTES]

    # Structured perceptron over sampled adjacent pairs.
    tr_arr = np.frombuffer(tr_state, dtype=np.uint8).astype(np.int64)
    xs = tr_arr[:-1:OPT_STRIDE]
    ys = tr_arr[1::OPT_STRIDE][:len(xs)]
    Pf = train_head_P(S, xs, ys)

    # Fire-region samples for hill-climb polish + gate evaluation. The
    # head only fires where BOTH the exact pair match and the confident
    # single match miss: pair_d > PAIR_GATE AND min_d > HEAD_GATE.
    def is_fire(r):
        return (r[0] is not None and r[0] > HEAD_GATE
                and (r[3] is None or r[3] > PAIR_GATE))

    hc_recs = mirror_state(tr_state[:400000], stride=4)
    fire_x = np.asarray([r[5] for r in hc_recs if is_fire(r)],
                        dtype=np.int64)
    fire_y = np.asarray([r[1] for r in hc_recs if is_fire(r)],
                        dtype=np.int64)

    # tau sweep scored on the training fire positions.
    P = quantise_P(Pf, 0.5)
    best_tau, best_ha = 0.5, -1.0
    for tau in (0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7):
        ha = float(np.mean(head_preds(fire_x, emb, quantise_P(Pf, tau))
                           == fire_y)) if len(fire_x) else 0.0
        if ha > best_ha:
            best_ha, best_tau = ha, tau
    P = quantise_P(Pf, best_tau)
    print(f"head perceptron: tau={best_tau} fire-acc={best_ha:.4f} "
          f"(fires={len(fire_x)})")
    P, head_acc_train = hillclimb_P(P, emb, fire_x, fire_y)
    print(f"head hill-climb: fire-acc={head_acc_train:.4f} "
          f"nnz={int((P != 0).sum())}")

    # Blended accuracy = the cartridge's real score: exact pair match
    # -> pair successor; confident single match -> successor; else head.
    def blended_acc(recs, P_x, gate, pair_gate=PAIR_GATE):
        fx = np.asarray([r[5] for r in recs
                         if r[0] is not None and r[0] > gate
                         and (r[3] is None or r[3] > pair_gate)],
                        dtype=np.int64)
        hp = iter(head_preds(fx, emb, P_x))
        hits = total = 0
        for min_d, nxt, succ, pd, psucc, xt in recs:
            if min_d is None:
                continue                    # echo on empty window
            total += 1
            if pd is not None and pd <= pair_gate:
                hits += int(psucc == nxt)
            elif min_d <= gate:
                hits += int(succ == nxt)
            else:
                hits += int(next(hp) == nxt)
        return hits / max(1, total)

    dev_recs = mirror_state(dev, stride=EVAL_STRIDE)
    best_blend = blended_acc(dev_recs, P, HEAD_GATE)
    head_acc_dev = float(np.mean(head_preds(
        np.asarray([r[5] for r in dev_recs if is_fire(r)],
                   dtype=np.int64), emb, P)
        == np.asarray([r[1] for r in dev_recs if is_fire(r)]))) \
        if any(is_fire(r) for r in dev_recs) else 0.0
    pair_hits = sum(1 for r in dev_recs
                    if r[3] is not None and r[3] <= PAIR_GATE
                    and r[4] == r[1])
    pair_cov = sum(1 for r in dev_recs
                   if r[3] is not None and r[3] <= PAIR_GATE)
    print(f"head: gate={HEAD_GATE} dev blended={best_blend:.4f} "
          f"(head-alone {head_acc_dev:.4f})")
    print(f"pair: coverage={pair_cov}/{len(dev_recs)} "
          f"acc={pair_hits / max(1, pair_cov):.4f}")
    for g in (0, 96, 128, 192, 256):
        print(f"  gate>{g}: dev blended acc="
              f"{blended_acc(dev_recs, P, g):.4f}")
    for pg in (0, 96, 160):
        print(f"  pair_gate>{pg}: dev blended acc="
              f"{blended_acc(dev_recs, P, HEAD_GATE, pg):.4f}")

    tst_recs = mirror_state(test, stride=1)
    tst_acc = blended_acc(tst_recs, P, HEAD_GATE)
    dev_recs_full = mirror_state(dev, stride=1)
    dev_acc = blended_acc(dev_recs_full, P, HEAD_GATE)
    tr_recs = mirror_state(tr_state, stride=1)
    tr_acc = blended_acc(tr_recs, P, HEAD_GATE)
    print(f"blended: train={tr_acc:.4f} dev={dev_acc:.4f} "
          f"test={tst_acc:.4f}")

    # The cartridge ships the zero-recurrence dynamics: A_W = 0, B_W = 0,
    # Gate_W = 1s ->  h_t = P . E(x_t), a pure current-token fingerprint.
    a_zero = [0] * (HID * HID)
    b_zero = [0] * HID
    g_ones = [1] * HID
    blob = serialize(emb, P, a_w=a_zero, b_w=b_zero, g_w=g_ones)
    OUT_MODEL.write_bytes(blob)
    print(f"wrote {OUT_MODEL} ({len(blob)} bytes)")

    # Frozen probe vectors for the Ada battery: full mirror of the hybrid
    # forward path (attention successor OR hidden head, gate-switched).
    # The mirror yields one rec per successor pair, so pad the probe wi'
    # a sentinel byte tae collect a prediction fer the last input token.
    recs = mirror_state(PROBE + b"\x00", stride=1)[:len(PROBE)]
    preds = []
    for i, r in enumerate(recs):
        if r[0] is None:
            preds.append(PROBE[i])                # empty window -> echo
        elif r[3] is not None and r[3] <= PAIR_GATE:
            preds.append(r[4])                    # exact pair -> its succ
        elif r[0] <= HEAD_GATE:
            preds.append(r[2])                    # confident -> successor
        else:
            preds.append(int(head_preds([r[5]], emb, P)[0]))  # weak -> head

    metrics = {
        "format": "SEQ-TRAINER-METRICS",
        "version": 2,
        "geometry": {"vocab": VOCAB, "feature": FEAT, "hidden": HID,
                     "seq": SEQ, "context": CTX},
        "weights": {"A": A, "B": B, "D": D,
                    "head_tau": best_tau, "gate": HEAD_GATE,
                    "pair_gate": PAIR_GATE},
        "head": {"train_acc": head_acc_train, "dev_acc": head_acc_dev,
                 "dev_blended": best_blend},
        "pair": {"dev_coverage": pair_cov, "dev_hits": pair_hits},
        "train_bytes": len(train),
        "accuracy": {
            "train": tr_acc, "dev": dev_acc, "test": tst_acc,
        },
        "baselines": {
            "dominant_successor_test": base_dom,
            "identity_bigram_train": base_id_train,
            "identity_bigram_test": base_id_test,
        },
        "probe": {"input_len": len(PROBE), "preds": preds},
        "model": "models/alb_seq.albm",
        "model_type": 4,
        "model_bytes": len(blob),
    }
    OUT_METRICS.write_text(json.dumps(metrics, indent=1) + "\n")
    print(json.dumps(metrics["accuracy"], indent=1))
    print(json.dumps(metrics["baselines"], indent=1))

    # Ada golden spec (deterministic mirror o' the trained predictions).
    inp = ", ".join(str(b) for b in PROBE)
    exp = ", ".join(str(p) for p in preds)
    OUT_GOLDEN.write_text(
        "--  Seq_Golden.ads - generated by tools/train_sequence.py.\n"
        "--  Frozen probe stream + expected predictions fir da trained\n"
        "--  type-4 sequence cartridge (models/alb_seq.albm). Regenerated\n"
        "--  on ilka training run; the battery loads the cartridge an\n"
        "--  demands bit-exact agreement.\n"
        "\n"
        "with Tokenizer_Static;\n"
        "\n"
        "package Seq_Golden is\n"
        "   pragma SPARK_Mode (On);\n"
        "\n"
        f"   Probe_Len : constant := {len(PROBE)};\n"
        "\n"
        "   Input_Stream : constant\n"
        "     array (1 .. Probe_Len) of Tokenizer_Static.Token_Id :=\n"
        f"       ({inp});\n"
        "\n"
        "   Expected_Preds : constant\n"
        "     array (1 .. Probe_Len) of Tokenizer_Static.Token_Id :=\n"
        f"       ({exp});\n"
        "\n"
        "end Seq_Golden;\n")
    print(f"wrote {OUT_GOLDEN}")


if __name__ == "__main__":
    sys.exit(main())
