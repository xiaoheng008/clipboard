import json, re, sys, html
M=sys.argv[1]
enc=json.load(open(M+'/vocab.json'))
merges=open(M+'/merges.txt',encoding='utf-8').read().split('\n')[1:]
merges=[tuple(m.split()) for m in merges if m.strip()]
ranks=dict(zip(merges,range(len(merges))))
def bytes_to_unicode():
    bs=list(range(ord("!"),ord("~")+1))+list(range(ord("¡"),ord("¬")+1))+list(range(ord("®"),ord("ÿ")+1))
    cs=bs[:]; n=0
    for b in range(256):
        if b not in bs: bs.append(b); cs.append(256+n); n+=1
    return dict(zip(bs,map(chr,cs)))
b2u=bytes_to_unicode()
def bpe(token):
    word=tuple(token[:-1])+(token[-1]+'</w>',)
    while len(word)>1:
        pairs=set(zip(word,word[1:]))
        best=min(pairs,key=lambda p: ranks.get(p,1e18))
        if best not in ranks: break
        a,b=best; new=[]; i=0
        while i<len(word):
            if i<len(word)-1 and word[i]==a and word[i+1]==b: new.append(a+b); i+=2
            else: new.append(word[i]); i+=1
        word=tuple(new)
    return word
pat=re.compile(r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[^\W\d_]+|\d|[^\s\w]+|_+", re.IGNORECASE)
def encode(text):
    text=re.sub(r'\s+',' ',html.unescape(text)).strip().lower()
    ids=[]
    for tok in pat.findall(text):
        tok=''.join(b2u[b] for b in tok.encode('utf-8'))
        ids+= [enc[t] for t in bpe(tok)]
    return ids
for s in sys.argv[2:]: print(json.dumps(s, ensure_ascii=False), encode(s))
