import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('appcast', pathlib.Path(__file__).with_name('sparkle-appcast.py'))
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.archive = self.root / 'update.zip'
        self.feed = self.root / 'appcast.xml'
        self.feed.write_text('<rss><channel><title>Test</title></channel></rss>')
        self.info = {'CFBundleIdentifier': 'app.pocketdesk.host', 'CFBundleVersion': '101',
                     'CFBundleShortVersionString': '1.2', 'SUPublicEDKey': 'test-public-key'}
        self.write_archive()

    def write_archive(self):
        with zipfile.ZipFile(self.archive, 'w') as bundle:
            bundle.writestr('PocketDesk.app/Contents/Info.plist', plistlib.dumps(self.info))

    def test_reads_actual_archive_build(self):
        self.assertEqual(appcast.app_metadata(self.archive)['CFBundleVersion'], '101')

    def test_rejects_wrong_app(self):
        self.info['CFBundleIdentifier'] = 'other.app'
        self.write_archive()
        with self.assertRaises(ValueError):
            appcast.app_metadata(self.archive)

    def test_rejects_unversioned_or_foreign_download(self):
        for url in ['http://example.com/update.zip', 'https://github.com/DamilolaDami/pocketdesk/releases/latest/download/update.zip']:
            with self.assertRaises(ValueError):
                appcast.prepare(self.feed, self.archive, url, pathlib.Path('/tools/sign_update'))

    @patch.object(appcast.subprocess, 'run')
    @patch.object(appcast.subprocess, 'check_output', side_effect=['test-public-key', 'A' * 86 + '=='])
    def test_preserves_old_entries_and_signs_before_replacing(self, output, run):
        self.feed.write_text('<rss xmlns:sparkle="' + appcast.SPARKLE + '"><channel><item><sparkle:version>100</sparkle:version></item></channel></rss>')
        appcast.prepare(self.feed, self.archive, 'https://github.com/DamilolaDami/pocketdesk/releases/download/v1.2/update.zip', pathlib.Path('/tools/sign_update'))
        channel = appcast.ET.parse(self.feed).getroot().find('channel')
        self.assertEqual({i.findtext('{' + appcast.SPARKLE + '}version') for i in channel.findall('item')}, {'100', '101'})
        self.assertEqual(channel.findall('item')[0].findtext('{' + appcast.SPARKLE + '}version'), '101')
        self.assertEqual(run.call_count, 2)
        self.assertIn('--verify', run.call_args.args[0])

    @patch.object(appcast.subprocess, 'check_output', side_effect=['test-public-key', 'A' * 86 + '=='])
    def test_duplicate_build_does_not_replace_feed(self, output):
        self.feed.write_text('<rss xmlns:sparkle="' + appcast.SPARKLE + '"><channel><item><sparkle:version>101</sparkle:version></item></channel></rss>')
        original = self.feed.read_bytes()
        with self.assertRaises(ValueError):
            appcast.prepare(self.feed, self.archive, 'https://github.com/DamilolaDami/pocketdesk/releases/download/v1.2/update.zip', pathlib.Path('/tools/sign_update'))
        self.assertEqual(self.feed.read_bytes(), original)

    @patch.object(appcast.subprocess, 'run', side_effect=RuntimeError('signing failed'))
    @patch.object(appcast.subprocess, 'check_output', side_effect=['test-public-key', 'A' * 86 + '=='])
    def test_signing_failure_preserves_feed(self, output, run):
        original = self.feed.read_bytes()
        with self.assertRaises(RuntimeError):
            appcast.prepare(self.feed, self.archive, 'https://github.com/DamilolaDami/pocketdesk/releases/download/v1.2/update.zip', pathlib.Path('/tools/sign_update'))
        self.assertEqual(self.feed.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
