#!/usr/bin/env python3
"""Generates Sources/ClipCore/Models/BuiltinModels.swift.

Sizes and sha256 values were measured on 2026-10-17: weight.bin / model.mlmodel hashes are the
HuggingFace LFS oids (== sha256, cross-checked locally for S2); Manifest.json hashes were computed
from downloaded files. Re-run this script after changing the table below.
"""
import json, pathlib

HF = "https://huggingface.co/apple/coreml-mobileclip/resolve/main"
TOK = "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main"

PKG = {  # variant -> role -> [(file, size, sha256)]
    "s0": {
        "image": [("Manifest.json", 617, "fe07dde983dae92c1799132816ce55f9ff8487f2681b530abf7222025aa27fa4"),
                  ("Data/com.apple.CoreML/model.mlmodel", 153260, "2c1afa132c41c6535817cc67894bd7484bc2cbd084ed5e2f12b24f611af17591"),
                  ("Data/com.apple.CoreML/weights/weight.bin", 22717696, "87d8f63997bbd2f38ba7defeaaa2c571928bdece56aa9629542198b3ce906ed6")],
        "text": [("Manifest.json", 617, "a7cb0864a627468a953afd107262097ad74a0fcf82e49df7e00b9c86385bb7db"),
                 ("Data/com.apple.CoreML/model.mlmodel", 57953, "81eba836ff4dbc8ae021d70006288b533ba7eed3c2973d245b0d5ea047305bfd"),
                 ("Data/com.apple.CoreML/weights/weight.bin", 84871616, "34723e51445b2630106e94e1fdbebed80e7676b404fb839f4eb9bec97bdcad68")],
    },
    "s2": {
        "image": [("Manifest.json", 617, "6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6"),
                  ("Data/com.apple.CoreML/model.mlmodel", 299056, "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b"),
                  ("Data/com.apple.CoreML/weights/weight.bin", 71397632, "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00")],
        "text": [("Manifest.json", 617, "ea6a189d82fee2ee36eadb99022cda66a7f6b50a4bf9cc1d9541c7ea3b4242a0"),
                 ("Data/com.apple.CoreML/model.mlmodel", 128127, "b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80"),
                 ("Data/com.apple.CoreML/weights/weight.bin", 126866880, "8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce")],
    },
    "blt": {
        "image": [("Manifest.json", 617, "112a034d18e8c76b21e491a94ee8236e6989021c13dfe9ea8ecd3ac6dc2bdabe"),
                  ("Data/com.apple.CoreML/model.mlmodel", 136798, "3acaec5c9eca2f27b7dc6d3bffb19cbb94d34e97cdd8aec70987e4ae7de09fae"),
                  ("Data/com.apple.CoreML/weights/weight.bin", 172707392, "c12ec418eadf5d536f11e2e575b26c0d0bbc1270a7080d97f218a0a11595c289")],
        "text": [("Manifest.json", 617, "7bffd0b82a4821ae8bbacd65f25036035b9462eef6edd1ee4879a446ca87f425"),
                 ("Data/com.apple.CoreML/model.mlmodel", 130291, "8a96162d32dcf3ba80c313d6126152a1f70e102a64547e4c8d1f69ce7f9b2384"),
                 ("Data/com.apple.CoreML/weights/weight.bin", 126878848, "bd0a34acafc0fd5fd142afd2a0c27aacd16edcce8aa7410870f82541a3fec000")],
    },
}
TOKENIZER = [("vocab.json", 862328, "5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363"),
             ("merges.txt", 524657, "f526393189112391ce6f9795d4695f704121ce452c3aad1f5335cc41337eba85")]

# variant -> (id, name, tier, minMemoryGB, imageSize) ; imageSize read from each model's description.
META = {
    "s0": ("mobileclip-s0@1", "MobileCLIP S0（轻量）", 1, 0, 256),
    "s2": ("mobileclip-s2@1", "MobileCLIP S2（均衡）", 2, 16, 256),
    "blt": ("mobileclip-blt@1", "MobileCLIP B-LT（最佳）", 3, 32, 224),
}

models = []
for v, (mid, name, tier, mem, size) in META.items():
    files = []
    for role in ("image", "text"):
        for f, n, h in PKG[v][role]:
            files.append({"path": f"{role}.mlpackage/{f}", "url": f"{HF}/mobileclip_{v}_{role}.mlpackage/{f}", "sha256": h, "size": n})
    for f, n, h in TOKENIZER:
        files.append({"path": f, "url": f"{TOK}/{f}", "sha256": h, "size": n})
    models.append({"id": mid, "family": "coreml-clip", "displayName": name, "tier": tier, "dim": 512,
                   "imageSize": size, "contextLength": 77, "minMemoryGB": mem, "imageInput": "image",
                   "textInput": "text", "output": "final_emb_1", "tokenizer": "clip-bpe", "files": files,
                   "notes": "Apple MobileCLIP (apple-ascl license). English text encoder."})
# Multilingual models (added 2026-10-17, Q9/Q10). sha256 = HF LFS oid, cross-checked locally.
SIG = "https://huggingface.co/FluidInference/siglip2-base-patch16-256-coreml/resolve/main"
SIGPKG = "siglip2-base-patch16-256-{role}-fp16.mlpackage"
sig_files = []
for role, rows in {
    "image": [("Manifest.json", 617, "964a40aa63c2d201a30f0aeab68aef8abc95c854a34f4cae533051cd99996e72"),
              ("Data/com.apple.CoreML/model.mlmodel", 140042, "702fdc0b557984e16e4bbcce4eec3568f08a7459bd3c27c770a487823bda808b"),
              ("Data/com.apple.CoreML/weights/weight.bin", 184692800, "da086438b60ada3566f8c91bd8a632462f28d344186e7f60cb5abd223d2e99a8")],
    "text": [("Manifest.json", 617, "a5dfacf23259261d32c5af26c5cfe4c41a44f0584739b2ef10e70c7f11c2a620"),
             ("Data/com.apple.CoreML/model.mlmodel", 128779, "69fce0f538fbe78c45b953e1cc396fb912d701c6f985ac825bdec92833aca452"),
             ("Data/com.apple.CoreML/weights/weight.bin", 564620224, "9a52dd8222973b6b4cdf55983689bb2fa18a27fcd20b83f8d8fb89de544530b5")],
}.items():
    for f, n, h in rows:
        sig_files.append({"path": f"{role}.mlpackage/{f}", "url": f"{SIG}/{SIGPKG.format(role=role)}/{f}", "sha256": h, "size": n})
sig_files.append({"path": "tokenizer.json", "url": f"{SIG}/tokenizer.json", "sha256": "caefd63119539a63be2d55ef3e05023fbb793948c4bda5bc0c366b42a382f903", "size": 34363038})
models.append({"id": "siglip2-base@1", "family": "coreml-siglip", "displayName": "SigLIP2 Base（中英文搜图）", "tier": 4, "dim": 768,
               "imageSize": 256, "minMemoryGB": 8, "imageInput": "pixel_values", "textInput": "input_ids", "output": "image_embeds",
               "textLength": 64, "padID": 0, "lowercase": True, "imageMean": [0.5, 0.5, 0.5], "imageStd": [0.5, 0.5, 0.5],
               "tokenizer": "hf", "tokenizerFile": "tokenizer.json", "multilingual": True, "scoreFloor": 0.09, "scoreMargin": 0.03,
               "files": sig_files,
               "notes": "Google SigLIP 2 (Apache-2.0), Core ML conversion by Fluid Inference. Text output: text_embeds."})

E5 = "https://huggingface.co/wolfram-pro/multilingual-e5-small-coreml/resolve/main"
e5_files = [{"path": f"text.mlpackage/{f}", "url": f"{E5}/MultilingualE5Small.mlpackage/{f}", "sha256": h, "size": n} for f, n, h in [
    ("Manifest.json", 617, "f33ab12817d30783d36fb9eb1f3ebf4483ca088caf7f0ea13fff54222b71ae16"),
    ("Data/com.apple.CoreML/model.mlmodel", 283336, "121f9988a394565994f5aa26cd8a86a7d32b76e0e5b986ecee07070e5b2f8b27"),
    ("Data/com.apple.CoreML/weights/weight.bin", 235028736, "ff0331d7b3e44efd122d3592caf82a09e1d88a0bbd458fc8a24223ebb14a3ba7")]]
e5_files.append({"path": "tokenizer.json", "url": f"{E5}/tokenizer.json", "sha256": "0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39", "size": 17082730})
models.append({"id": "multilingual-e5-small@1", "family": "coreml-text-embed", "displayName": "Multilingual E5 Small（中文搜英文较弱）",
               "tier": 1, "dim": 384, "minMemoryGB": 0, "textInput": "input_ids", "attentionMaskInput": "attention_mask", "output": "embedding",
               "inputLengths": [16, 32, 64, 128, 256, 512], "padID": 1, "queryPrefix": "query: ", "documentPrefix": "passage: ",
               "tokenizer": "hf", "tokenizerFile": "tokenizer.json", "multilingual": True, "scoreFloor": 0.84, "scoreMargin": 0.012,
               "files": e5_files,
               "notes": "intfloat/multilingual-e5-small (MIT), Core ML conversion by wolfram-pro. Pooling + L2 norm inside the graph."})


# Text models chosen by the zh/en eval (2026-10-17, Q18; evidence/7B/text-model-eval-v1.txt).
QW = "https://huggingface.co/erjigit17/qwen3-embedding-0.6b-ane-coreml-8bit/resolve/main"
qw_files = []
for role, pkg, rows in [
    ("text", "qwen3-b1_s128-8bit.mlpackage", [("Manifest.json", 617, "455eb2d5806f118b51fab989fbb6d3057757024bbd4168996b150a939602dd31"),
        ("Data/com.apple.CoreML/model.mlmodel", 645191, "7d24aa9fc46fcea3d17af383e316ee119a2187606c1c6c39039edbc4cbcf0094"),
        ("Data/com.apple.CoreML/weights/weight.bin", 596927872, "a27e83e63117af006e601b36955c7539a2b5e4f8ab2984691f8845dcec4a16a0")]),
    ("text512", "qwen3-b1_s512-8bit.mlpackage", [("Manifest.json", 617, "32cf218afcb9305ef53e9f623c79902e6f99fa110a49d736063db905a2e11346"),
        ("Data/com.apple.CoreML/model.mlmodel", 645191, "e1dc3cf755da81ddf2cb30a9b83c4a815c4a35133a3a8e6a1bb56dc80977d5be"),
        ("Data/com.apple.CoreML/weights/weight.bin", 597271936, "f8eb20de1b1e94349277b98b211e4969e4310fbf10e1a1f547a1b6981cbcf9d4")])]:
    for f, n, h in rows:
        qw_files.append({"path": f"{role}.mlpackage/{f}", "url": f"{QW}/{pkg}/{f}", "sha256": h, "size": n})
qw_files.append({"path": "tokenizer.json", "url": f"{QW}/tokenizer.json", "sha256": "def76fb086971c7867b829c23a26261e38d9d74e02139253b38aeb9df8b4b50a", "size": 11423705})
models.append({"id": "qwen3-embedding-0.6b@1", "family": "coreml-text-embed", "displayName": "Qwen3 Embedding 0.6B（中英文文本语义，推荐）",
               "tier": 4, "dim": 1024, "minMemoryGB": 16, "textInput": "input_ids", "attentionMaskInput": "attention_mask", "output": "embedding",
               "textPackages": [{"role": "text", "length": 128}, {"role": "text512", "length": 512}], "padID": 151643, "padLeft": True,
               "queryPrefix": "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:", "documentPrefix": "",
               "tokenizer": "hf", "tokenizerFile": "tokenizer.json", "multilingual": True, "scoreFloor": 0.45, "scoreMargin": 0.08,
               "files": qw_files,
               "notes": "Qwen/Qwen3-Embedding-0.6B (Apache-2.0); Core ML by neuradex, 8-bit by erjigit17. Last-token pooling in the graph."})

GR = "https://huggingface.co/characteragent/granite-embedding-97m-multilingual-r2-coreml/resolve/main/GraniteEmbedding97mMultilingualR2.mlpackage"
gr_files = [{"path": f"text.mlpackage/{f}", "url": f"{GR}/{f}", "sha256": h, "size": n} for f, n, h in [
    ("Manifest.json", 617, "4b1d83a52239e83bed576458e8d3e1ba4aa303385c619e825ebd62f1ff065032"),
    ("Data/com.apple.CoreML/model.mlmodel", 172838, "c0553e1cd2455ac6c5196d8658768dcc9e77ced18cf5c847e002af6951b125a7"),
    ("Data/com.apple.CoreML/weights/weight.bin", 98079232, "a9ff4dce357172570f18de7062b2a06f88d6b9b439f38d99ae110af36a810b1c")]]
gr_files.append({"path": "tokenizer.json", "url": "https://huggingface.co/ibm-granite/granite-embedding-97m-multilingual-r2/resolve/main/tokenizer.json",
                 "sha256": "4f2842d568e2724370aec203652a42ac783c7937f8347a1a2cc7506d71f1582f", "size": 25301672})
models.append({"id": "granite-embedding-97m@1", "family": "coreml-text-embed", "displayName": "Granite Embedding 97M（轻量，中英文）",
               "tier": 2, "dim": 384, "minMemoryGB": 0, "textInput": "input_ids", "attentionMaskInput": "attention_mask", "output": "embedding",
               "inputLengths": [16, 32, 64, 128, 256, 512], "padID": 179935,
               # Measured 2026-10-17 (M4): Neural Engine ≈ 30 s on every load (not cached); CPU 1.3 s load,
               # 3 ms / query, 5 ms / document — fastest for this small int8 model.
               "computeUnits": "cpuOnly",
               "tokenizer": "hf", "tokenizerFile": "tokenizer.json", "multilingual": True, "scoreFloor": 0.83, "scoreMargin": 0.03,
               "files": gr_files,
               "notes": "ibm-granite/granite-embedding-97m-multilingual-r2 (Apache-2.0), Core ML int8 by characteragent."})

models.append({"id": "vision-featureprint@1", "family": "vision-featureprint", "displayName": "Apple Vision 特征（无需下载，仅相似图片）",
               "tier": 0, "dim": 768, "minMemoryGB": 0, "files": [],
               "notes": "Similar-image strip only; cannot answer text queries — prefer SigLIP2, which also powers similar images."})

out = pathlib.Path(__file__).resolve().parent.parent / "Sources/ClipCore/Models/BuiltinModels.swift"
body = json.dumps({"models": models}, ensure_ascii=False, indent=1)
out.write_text("// Generated by scripts/gen_builtin_models.py — do not edit by hand.\n"
               "enum BuiltinModels {\n    static let json = #\"\"\"\n" + body + "\n\"\"\"#\n}\n", encoding="utf-8")
print("wrote", out)
