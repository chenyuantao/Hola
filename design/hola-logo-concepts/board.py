from pathlib import Path
import ast, subprocess, xml.etree.ElementTree as ET
p=Path(__file__).parent
items=ast.literal_eval((p/'concept-data.txt').read_text())
board=['<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="990" viewBox="0 0 1800 990"><rect width="1800" height="990" fill="#FAF8F4"/><g font-family="Helvetica, PingFang SC, sans-serif" fill="#292D29"><text x="70" y="100" font-size="54" font-weight="600">Hola · 言好</text><text x="72" y="151" font-size="23" fill="#71746E">你的意思，更好的表达。</text><text x="1728" y="101" text-anchor="end" font-size="13" letter-spacing="2">BRAND EXPLORATION / 02</text>']
for i,(slug,name,sub,col,bg,desc,body) in enumerate(items):
 x=70+i*338
 board.append(f'<rect x="{x}" y="220" width="310" height="420" rx="24" fill="{bg}"/><svg x="{x+65}" y="260" width="180" height="180" viewBox="0 0 100 100" color="{col}">{body}</svg><text x="{x+155}" y="500" text-anchor="middle" font-size="32" font-weight="600" fill="{col}">Hola · 言好</text><text x="{x+155}" y="544" text-anchor="middle" font-size="15" fill="{col}">你的意思，更好的表达。</text><text x="{x}" y="688" font-size="12" letter-spacing="1" fill="#73766E">0{i+1} / {sub.split(" / ")[0]}</text><text x="{x}" y="728" font-size="26" font-weight="600">{name}</text><svg x="{x}" y="775" width="20" height="20" viewBox="0 0 100 100">{body}</svg><svg x="{x+42}" y="767" width="36" height="36" viewBox="0 0 100 100">{body}</svg><rect x="{x+110}" y="755" width="60" height="60" rx="16" fill="#292D29"/><svg x="{x+119}" y="764" width="42" height="42" color="white" viewBox="0 0 100 100">{body}</svg>')
 lock=f'<svg xmlns="http://www.w3.org/2000/svg" width="720" height="240" viewBox="0 0 720 240" color="{col}"><svg x="20" y="25" width="185" height="185" viewBox="0 0 100 100">{body}</svg><g fill="currentColor" font-family="Helvetica, PingFang SC, sans-serif"><text x="235" y="115" font-size="56" font-weight="600">Hola · 言好</text><text x="238" y="166" font-size="24">你的意思，更好的表达。</text></g></svg>'
 (p/(slug+'-lockup.svg')).write_text(lock)
 subprocess.run(['rsvg-convert','-o',str(p/(slug+'-lockup.png')),str(p/(slug+'-lockup.svg'))],check=True)
board.append('<path d="M70 873H1730" stroke="#DDDCD5"/><text x="70" y="930" font-size="17" fill="#73766E">保留你的本意 · 让表达自然发生</text><text x="1730" y="930" text-anchor="end" font-size="15" fill="#73766E">五个独立方向 / 品牌组合 · 单色缩略 · 深色适配</text></g></svg>')
(p/'overview.svg').write_text(''.join(board))
subprocess.run(['rsvg-convert','-o',str(p/'overview.png'),str(p/'overview.svg')],check=True)
with (p/'README.md').open('a') as f: f.write('\n## 本轮品牌简报\n\n品牌：Hola · 言好。标语：你的意思，更好的表达。\n设计主张：保留本意，让表达更自然。上一轮设计保留在 ../logo-concepts。\n每款新增 -lockup.svg / -lockup.png 品牌组合。组合 SVG 的字标使用系统字体，未转曲；独立符号完全由矢量路径构成。\n重新生成：先运行 generate.py，再运行 board.py。\n')
for f in p.glob('*.svg'): ET.parse(f)
print('5 concepts and 5 brand lockups rendered; SVG XML validated.')
