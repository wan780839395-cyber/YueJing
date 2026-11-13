"""Source wiring only. Browser behavior checked separately; native execution remains zero."""
from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
js=read('App/EPUB/EPUBLocationScript.swift')
ui=read('App/EPUB/EPUBSettingsView.swift')
vm=read('App/EPUB/EPUBReaderViewModel.swift')
host=read('Tests/YueJingHostTests/EPUBReaderHostTests.swift')
checks={}
def check(name,value): checks[name]=bool(value)
check('validated stored preference reaches JS scale','"authorTextScale": preferences.validated.fontSize / 20' in js)
check('scale has bounded original-mode contract','Math.max(0.7, Math.min(1.8, config.authorTextScale))' in js and 'config.layoutMode !== "reader" && Number.isFinite(config.authorTextScale)' in js)
scale=js.split('function applyAuthorTextScale()',1)[1].split('function rebaseAuthorStyle',1)[0]
check('all baseline reads precede scale writes',scale.index('window.getComputedStyle(element)')<scale.index('pending.forEach(function(record)'))
check('only text metrics are overridden','setProperty("font-size"' in scale and 'setProperty("line-height"' in scale and 'setProperty("font-family"' not in scale and 'textContent =' not in scale)
check('original inline priority restored and records released','record.element.style.setProperty(property, original.value, original.priority)' in js and 'chapter.textScaleRecords = null' in js)
check('scale reaches both restore and neighbor commit',js.count('applyAuthorTextScale();')==2 and js.index('applyAuthorTextScale();',js.index('function restoreAndConfirm'))<js.index('scrollToChapterEnd()',js.index('function restoreAndConfirm')))
check('promotion fastpath has no reapplication','applyAuthorTextScale' not in js.split('if (config.preserveViewport === true) {',1)[1].split('if (state.scrollTimer',1)[0])
check('author UI no longer globally disables typography','typographySection.disabled' not in ui and 'EPUBAuthorScaleAdjustment(value: $draft.fontSize' in ui)
check('author preset and reset preserve reader spacing','if usesAuthorTypography {\n            // The existing preference is the scale contract; do not change reader line spacing.\n            draft.fontSize = preset.fontSize' in ui)
check('slider range percent and guarded submit agree','Slider(value: sliderValue, in: 14...36, step: 1' in ui and 'guard isActive(), proposed.isFinite else { return }' in ui and 'value * 5' in ui and 'if !dragging { commit() }' in ui)
check('binding calls original settings change and save path','preferences = value\n        changed()' in ui and 'activeReader.savePreferences(validated, sequence: prefSerial)' in vm and 'preserveTargetAnchor: target != nil' in vm)
check('native tests assert actual scale bounds and exact anchor','for size in [28.0, 36.0, 14.0, 20.0]' in host and 'base * scale' in host and 'scaled.node == sampled.node && scaled.utf16Offset == sampled.utf16Offset' in host)
check('native cold and warm keep persisted 140 percent','expectScaledAuthorStyles(try await readComputedStyles(in: warmController), scale: 1.4)' in host and 'expectScaledAuthorStyles(try await readComputedStyles(in: coldController), scale: 1.4)' in host)
print(json.dumps({'passed':all(checks.values()),'checks':checks,'native_executions':0,'swift_compiled':False},ensure_ascii=False,indent=2))
raise SystemExit(0 if all(checks.values()) else 1)
