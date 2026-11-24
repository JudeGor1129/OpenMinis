#!/usr/bin/env python3
"""Build349 source invariants + optional REAL Swift engine tests. No UIKit mocks.
Run: python3 scripts/test_chat_search_export_349.py
Swift unavailable is SKIPPED, never reported as a compile/test pass.
"""
import json, math, re, shutil, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'src/ios'
SEARCH = 'Agent/MessageList/CollectionViewMessageListV3/Search/'
def source(p): return (IOS / p).read_text()

class SourceGuards(unittest.TestCase):
    def test_stable_identity_and_reversible_unicode(self):
        engine = source(SEARCH+'ChatSearchEngine.swift')
        self.assertIn('let messageId: UUID', engine)
        self.assertIn('let blockId: UUID?', engine)
        self.assertIn('let ordinal: Int', engine)
        high = source(SEARCH+'ChatSearchHighlights.swift')
        self.assertIn('scalar.value > 0xFFFF ? 2 : 1', high)
        self.assertIn('offsets[NSMaxRange(range) - 1]', high)
        self.assertIn('NSIntersectionRange(hit.range, range)', high)
    def test_cap_reports_dropped_unit_results(self):
        engine = source(SEARCH+'ChatSearchEngine.swift')
        self.assertIn('limit: cap + 1', engine)
        self.assertIn('if n > cap { truncated = true }', engine)
    def test_same_length_edits_invalidate(self):
        units = source(SEARCH+'ChatSearchUnits.swift')
        self.assertIn('hit.raw == p.raw', units)
        self.assertNotIn('hit.length ==', units)
        control = source(SEARCH+'ChatSearchController.swift')
        self.assertIn('block.objectWillChange.sink', control)
        self.assertIn('self.generation == gen', control)
        self.assertIn('if self.dirty { self.schedule(landOnNewest: false', control)
    def test_paint_does_not_mutate_live_attributed_cache(self):
        text = source('Views/Chat/SelectableMarkdownView.swift')
        search = text.split('// MARK: - Build349 in-chat search paint')[1]
        self.assertNotIn('textStorage.addAttribute', search)
        self.assertNotIn('attributedText =', search)
        self.assertNotIn('invalidateIntrinsicContentSize', search)
        self.assertIn('addTemporaryAttribute(.backgroundColor', search)
        self.assertIn('searchSubscription = nil; searchToken = nil; clearSearchPaint()', search)
        self.assertIn('defer { textView.refreshSearchPaint() }', text)
        self.assertIn('defer { refreshSearchPaint() }', text)
    def test_original_sizing_lines_preserved(self):
        paths=['Agent/MessageList/CollectionViewMessageListV3.swift','Views/Chat/SelectableMarkdownView.swift']
        for p in paths:
            diff=subprocess.check_output(['git','diff','--unified=0','--','src/ios/'+p],cwd=ROOT,text=True)
            removed=[x for x in diff.splitlines() if x.startswith('-') and not x.startswith('---')]
            self.assertEqual([],removed,p+' must remain additive')
    def test_search_navigation_re_resolves_and_does_not_pin(self):
        text=source('Agent/MessageList/CollectionViewMessageListV3.swift')
        nav=text.split('private func navigateSearch')[1].split('func scrollToLastItem')[0]
        self.assertIn('ds.indexPath(for: item)', nav)
        self.assertIn('self.dataSource?.indexPath(for: item)', nav)
        self.assertIn('scrollMode = .userBrowsing', nav)
        self.assertIn('generation == self.searchNavigationGeneration', nav)
        self.assertNotIn('scrollToBottom', nav)
        self.assertIn('searchNavigationGeneration += 1 // user interaction', text)
        self.assertEqual(text.count('.environment(\\.chatSearchHighlights, chatSearch?.highlights)'),4)
    def test_export_snapshot_is_immutable_and_ordered(self):
        model=source('Views/Chat/ChatShareModel.swift')
        self.assertIn('let markdown: String', model)
        self.assertIn('let messageId: UUID', model)
        self.assertIn('items.filter { selected.contains($0.id) }', model)
        self.assertIn('parts.append(item.markdown)', model)
        self.assertIn('removingPercentEncoding', model)
        self.assertIn('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~', model)
    def test_pdf_uses_real_text_and_old_renderer(self):
        renderer=source('Views/Chat/ChatExportRenderer.swift')
        self.assertIn('CTFrameDraw(frame, context)', renderer)
        self.assertIn('CTFrameGetVisibleStringRange(frame)', renderer)
        self.assertIn('offset += visible.length', renderer)
        self.assertIn('renderMarkdownBlocks(MarkdownContent(prepareMarkdownForRender', renderer)
        self.assertNotIn(' = ImageRenderer(', renderer)
        self.assertNotIn('drawHierarchy', renderer)
        self.assertNotIn('PDFPage(image:', renderer)
    def test_resource_and_bitmap_ceilings(self):
        model=source('Views/Chat/ChatShareModel.swift')
        for line in ['maxTotalUTF16 = 2_000_000','maxItemUTF16 = 500_000','maxPages = 200',
                     'maxImageParts = 64','maxAttachments = 128','maxBitmapPixels: CGFloat = 4_000_000']:
            self.assertIn(line,model)
        renderer=source('Views/Chat/ChatExportRenderer.swift')
        self.assertIn('try autoreleasepool',renderer)
        self.assertIn('CGImageDestinationFinalize(destination)',renderer)
        self.assertIn('CGImageSourceCreateThumbnailAtIndex',renderer)
        self.assertIn('resourceCount <= ChatShareExportBudget.maxAttachments',renderer)
        self.assertNotIn('.pngData()',renderer)
        self.assertNotIn('URLSession',renderer)
        for w in [390,768]:
            h=min(2048,8192/2,math.floor(4_000_000/(w*2*2)))
            self.assertLessEqual(math.ceil(w*2)*math.ceil(h*2),4_000_000)
    def test_ios15_ui_and_cancellation(self):
        view=source('Views/Chat/ChatShareSelectionView.swift')
        self.assertIn('NavigationView {',view)
        self.assertIn('UIActivityViewController(activityItems: urls',view)
        self.assertIn('exportTask?.cancel()',view)
        self.assertIn('if Task.isCancelled',view)
        self.assertNotIn('ShareLink(',view)
        self.assertNotIn('presentationDetents',view)
        self.assertNotIn('NavigationStack',view)


def run_swift():
    swiftc=shutil.which('swiftc')
    if not swiftc:
        print('SKIP: Swift compiler unavailable; UIKit/CoreText runtime and Xcode build NOT verified.')
        return True
    parser=source('Agent/Markdown/MinisMarkdownParser.swift').split('// MARK: - MarkdownContent')[0]
    parser='\n'.join(line for line in parser.splitlines() if not line.startswith('import cmark'))
    tests=(ROOT/'src/ios/MinisTests/Standalone/ChatSearch349Cases.swift').read_text()
    path=Path(tempfile.mkdtemp(prefix='MinisSearch349-'))
    code=path/'main.swift'
    code.write_text(parser+'\n'+source(SEARCH+'ChatSearchEngine.swift')+'\n'+source(SEARCH+'ChatSearchMarkdownText.swift')+'\n'+tests)
    binary=path/'tests'
    build=subprocess.run([swiftc,str(code),'-o',str(binary)],text=True)
    return build.returncode==0 and subprocess.run([str(binary)]).returncode==0

if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(SourceGuards)
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    swift=run_swift()
    raise SystemExit(0 if result.wasSuccessful() and swift else 1)
