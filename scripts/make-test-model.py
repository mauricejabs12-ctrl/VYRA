#!/usr/bin/env python3
"""Erzeugt ein winziges Qwen3-Testmodell (Zufallsgewichte, echter Qwen-Tokenizer) fuer die automatischen Tests
der llama.cpp-Anbindung. Es beweist Laden, Tokenisierung (inkl. <|im_start|>), Streaming, Abbruch, Prompt-Zwischenspeicher
und Grammatik – aber keine Antwortqualitaet (Zufallsgewichte erzeugen Unsinn).
Aufruf: python3 -I scripts/make-test-model.py <llama.cpp-Ordner> <ausgabe.gguf>"""
import os, sys
import numpy as np
llama = sys.argv[1]
sys.path.insert(0, os.path.join(llama, 'gguf-py'))
from gguf import GGUFReader, GGUFWriter
src = GGUFReader(os.path.join(llama, 'models', 'ggml-vocab-qwen2.gguf'))
def field(name):
    return src.fields[name]
tokens = [bytes(field('tokenizer.ggml.tokens').parts[i]).decode('utf-8', 'surrogatepass') for i in field('tokenizer.ggml.tokens').data]
ttypes = [int(field('tokenizer.ggml.token_type').parts[i][0]) for i in field('tokenizer.ggml.token_type').data]
merges = [bytes(field('tokenizer.ggml.merges').parts[i]).decode('utf-8') for i in field('tokenizer.ggml.merges').data]
n_vocab = len(tokens)
w = GGUFWriter(sys.argv[2], 'qwen3')
w.add_name('VYRA-Testmodell (Zufallsgewichte)')
E, FF, L, H, HKV, HD = 64, 128, 2, 4, 2, 16
w.add_context_length(4096); w.add_embedding_length(E); w.add_block_count(L); w.add_feed_forward_length(FF)
w.add_head_count(H); w.add_head_count_kv(HKV); w.add_key_length(HD); w.add_value_length(HD)
w.add_rope_freq_base(1000000.0); w.add_layer_norm_rms_eps(1e-6); w.add_file_type(0)
w.add_tokenizer_model('gpt2'); w.add_tokenizer_pre('qwen2')
w.add_token_list(tokens); w.add_token_types(ttypes); w.add_token_merges(merges)
w.add_eos_token_id(151645); w.add_bos_token_id(151643); w.add_pad_token_id(151643); w.add_add_bos_token(False)
tpl = os.path.join(llama, 'models', 'templates', 'Qwen-Qwen3-0.6B.jinja')
w.add_chat_template(open(tpl).read())
rng = np.random.default_rng(42)
def t(name, shape, scale=0.02):
    w.add_tensor(name, (rng.standard_normal(shape) * scale).astype(np.float32))
t('token_embd.weight', (n_vocab, E))
w.add_tensor('output_norm.weight', np.ones((E,), dtype=np.float32))
t('output.weight', (n_vocab, E))
for i in range(L):
    p = f'blk.{i}.'
    w.add_tensor(p + 'attn_norm.weight', np.ones((E,), dtype=np.float32))
    t(p + 'attn_q.weight', (H * HD, E)); t(p + 'attn_k.weight', (HKV * HD, E)); t(p + 'attn_v.weight', (HKV * HD, E)); t(p + 'attn_output.weight', (E, H * HD))
    w.add_tensor(p + 'attn_q_norm.weight', np.ones((HD,), dtype=np.float32)); w.add_tensor(p + 'attn_k_norm.weight', np.ones((HD,), dtype=np.float32))
    w.add_tensor(p + 'ffn_norm.weight', np.ones((E,), dtype=np.float32))
    t(p + 'ffn_gate.weight', (FF, E)); t(p + 'ffn_up.weight', (FF, E)); t(p + 'ffn_down.weight', (E, FF))
w.write_header_to_file(); w.write_kv_data_to_file(); w.write_tensors_to_file(); w.close()
print('ok', n_vocab)
