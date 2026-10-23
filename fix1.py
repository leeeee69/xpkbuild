import io, os

p = 'XPPanel.m'
s = open(p, encoding='utf-8').read()

s = s.replace("@property (nonatomic, assign) BOOL collapsed;",
              "@property (nonatomic, assign) BOOL collapsed;\n@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;")

s = s.replace("        [_card.widthAnchor constraintEqualToConstant:width],",
              "        (_widthConstraint = [_card.widthAnchor constraintEqualToConstant:width]),")

s = s.replace("- (BOOL)isCollapsed { return _collapsed; }",
              "- (BOOL)isCollapsed { return _collapsed; }\n\n"
              "- (void)updateWidth:(CGFloat)width {\n"
              "    self.widthConstraint.constant = width;\n"
              "    [self setNeedsLayout];\n"
              "}")

s = s.replace("        self.layer.cornerCurve = kCACornerCurveContinuous;\n",
              "        if (@available(iOS 13.0, *)) self.layer.cornerCurve = kCACornerCurveContinuous;\n")
s = s.replace("    _card.layer.cornerCurve = kCACornerCurveContinuous;\n",
              "    if (@available(iOS 13.0, *)) _card.layer.cornerCurve = kCACornerCurveContinuous;\n")
s = s.replace("    logo.layer.cornerCurve = kCACornerCurveContinuous;\n",
              "    if (@available(iOS 13.0, *)) logo.layer.cornerCurve = kCACornerCurveContinuous;\n")

old = """        NSNumber *m = XPGet(c, @"localDisplayMode");
        if (m && m.integerValue == idx) break;
        XPCall(c, @selector(changeLocalDisplayMode));"""
new = """        NSNumber *m = XPGet(c, @"localDisplayMode");
        if (!m) break;
        if (m.integerValue == idx) break;
        XPCall(c, @selector(changeLocalDisplayMode));"""
s = s.replace(old, new)

open(p, 'w', encoding='utf-8').write(s)

h = open('XPPanel.h', encoding='utf-8').read()
if 'updateWidth' not in h:
    h = h.replace("- (void)setCollapsed:(BOOL)collapsed;",
                  "- (void)setCollapsed:(BOOL)collapsed;\n- (void)updateWidth:(CGFloat)width;")
    open('XPPanel.h', 'w', encoding='utf-8').write(h)

print('widthConstraint:', 'widthConstraint' in s)
print('updateWidth m:', s.count('- (void)updateWidth'))
print('updateWidth h:', 'updateWidth' in open('XPPanel.h', encoding='utf-8').read())
print('cornerCurve guards:', s.count('@available(iOS 13.0'))
