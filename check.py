import os, re

def balance(path):
    s = open(path, encoding='utf-8').read()
    # 去掉字符串与注释，粗略统计
    s2 = re.sub(r'//[^\n]*', '', s)
    s2 = re.sub(r'/\*.*?\*/', '', s2, flags=re.S)
    s2 = re.sub(r'@"(?:[^"\\]|\\.)*"', '""', s2)
    s2 = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s2)
    return (s.count('{') - s.count('}'),
            s.count('(') - s.count(')'),
            s.count('[') - s.count(']'),
            s.count('@interface') - s.count('@end'))

for f in ['XPTheme.h', 'XPPanel.h', 'XPPanel.m', 'Tweak.xm']:
    if os.path.exists(f):
        print(f, balance(f))

s = open('XPPanel.m', encoding='utf-8').read()
props = set(re.findall(r'@property[^;]*?\b(\w+);', s))
# 使用到的 _ivar
ivars = set(re.findall(r'_([A-Za-z]\w*)', s))
declared = set('_' + p for p in props)
print('使用但未声明的 ivar:', sorted(v for v in ivars if '_' + v not in declared)[:20])
print('行数:', len(s.splitlines()))
