from pathlib import Path
p=Path(__file__).parent
items=[
('01-hola','开口即好','HELLO / MONOGRAM','#D36148','#FAEDE6','把小写 h 的肩部延展成对话尾巴。Hola 的首字母成为一个正在开口的符号，轻松、友好，也适合独立作应用图标。','<path d="M26 20v57h13V51c0-9 5-14 13-14s12 5 12 14v18c0 10 7 15 17 13V70c-4 0-4-2-4-6V50c0-16-9-26-23-26-6 0-11 2-15 6V20Z" fill="currentColor"/>'),
('02-yan','言之有意','YAN / LANGUAGE','#346B57','#EAF1E8','从「言」字提取点、横与口：上方是表达，下方是承载原意的开口。中文辨识最强，呈现克制、可信的编辑气质。','<g fill="currentColor"><rect x="43" y="13" width="14" height="9" rx="4.5"/><rect x="20" y="28" width="60" height="7" rx="3.5"/><rect x="32" y="42" width="36" height="6" rx="3"/></g><path d="M31 59h38v17H31Z" fill="none" stroke="currentColor" stroke-width="7" stroke-linejoin="round"/>'),
('03-unfold','让意思舒展','UNFOLD / EXPRESSION','#5265A4','#ECEFF7','同一条带子由紧凑的回环舒展成开放的弧线：意思仍是你的，表达变得从容。抽象、有动感，适合建立独立品牌。','<path d="M21 66V43c0-13 8-21 19-21s19 8 19 21v18c0 11-7 18-16 18s-16-7-16-16 7-16 16-16h21c10 0 15-6 15-15" fill="none" stroke="currentColor" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>'),
('04-seed','本意生花','SEED / MEANING','#A66730','#F5EEE0','两枚引号像种子展开的叶片，中间的留白保留生长空间。将文字、原意与更好的表达联系起来，柔和而有人文感。','<g fill="currentColor"><path d="M47 57C24 59 15 44 20 23c22-2 34 10 27 34Z"/><path d="M53 57c-7-23 5-35 27-34 5 21-4 36-27 34Z"/></g><path d="M50 60v19" fill="none" stroke="currentColor" stroke-width="8" stroke-linecap="round"/>'),
('05-resonance','话有所应','RESONANCE / UNDERSTOOD','#986078','#F4EAF0','两道相向的括弧，围住一颗不变的原点。原点代表你的意思，括弧代表更妥帖的表达与接收；简洁、安静、易缩放。','<g fill="none" stroke="currentColor" stroke-width="10" stroke-linecap="round"><path d="M34 23C12 36 12 64 34 77"/><path d="M66 23c22 13 22 41 0 54"/></g><circle cx="50" cy="50" r="10" fill="currentColor"/>')]
src=(p.parent/'logo-concepts/generate.py').read_text()
a=src.index('items=['); b=src.index('def svg(')
src=src[:a]+'items='+repr(items)+'\n'+src[b:]
src=src.replace('Hola','Hola · 言好').replace('让每句话，更好地被理解。','你的意思，更好的表达。').replace('推荐 01：友好直观    /    03：品牌辨识','推荐 01：亲和品牌    /    02：中文辨识').replace('推荐 01「会心一笑」或 03「言语之桥」。','推荐 01「开口即好」或 02「言之有意」。')
src=src.replace('<div class="art">{icon}</div>','<div class="art"><div class="brand">{icon}<strong>Hola <span>· 言好</span></strong><em>你的意思，更好的表达。</em></div></div>')
src=src.replace('.art svg{width:160px;height:160px}', '.art svg{width:120px;height:120px}.brand{text-align:center}.brand>svg{display:block;margin:0 auto 6px}.brand strong{display:block;font-size:26px;letter-spacing:-1px}.brand strong span{font-size:20px;letter-spacing:0}.brand em{display:block;margin-top:12px;font-size:12px;font-style:normal;letter-spacing:1px}')
(p/'generate.py').write_text(src)
(p/'concept-data.txt').write_text(repr(items))
