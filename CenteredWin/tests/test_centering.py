"""Unit tests for centering logic and hotkey parsing."""

import unittest
from unittest.mock import MagicMock, patch
import sys
import os

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hotkey_manager import _parse_hotkey, validate_hotkey_string


class TestHotkeyParsing(unittest.TestCase):
    """Tests for hotkey string parsing and validation."""

    def test_parse_valid_hotkey_single_modifier(self):
        """Test parsing hotkey with single modifier."""
        mods, vk = _parse_hotkey("Ctrl+C")
        self.assertEqual(mods, 0x0002)  # MOD_CONTROL
        self.assertEqual(vk, 0x43)  # 'C'

    def test_parse_valid_hotkey_multiple_modifiers(self):
        """Test parsing hotkey with multiple modifiers."""
        mods, vk = _parse_hotkey("Ctrl+Alt+C")
        self.assertEqual(mods, 0x0003)  # MOD_CONTROL | MOD_ALT
        self.assertEqual(vk, 0x43)  # 'C'

    def test_parse_valid_hotkey_all_modifiers(self):
        """Test parsing hotkey with all modifiers."""
        mods, vk = _parse_hotkey("Ctrl+Alt+Shift+Win+Z")
        expected_mods = 0x0001 | 0x0002 | 0x0004 | 0x0008  # All modifiers
        self.assertEqual(mods, expected_mods)
        self.assertEqual(vk, 0x5A)  # 'Z'

    def test_parse_case_insensitive(self):
        """Test that parsing is case insensitive."""
        mods1, vk1 = _parse_hotkey("ctrl+c")
        mods2, vk2 = _parse_hotkey("CTRL+C")
        mods3, vk3 = _parse_hotkey("Ctrl+C")
        self.assertEqual(mods1, mods2)
        self.assertEqual(mods2, mods3)
        self.assertEqual(vk1, vk2)
        self.assertEqual(vk2, vk3)

    def test_parse_control_variant(self):
        """Test that 'Control' is treated same as 'Ctrl'."""
        mods1, vk1 = _parse_hotkey("Ctrl+A")
        mods2, vk2 = _parse_hotkey("Control+A")
        self.assertEqual(mods1, mods2)
        self.assertEqual(vk1, vk2)

    def test_parse_invalid_no_key(self):
        """Test parsing hotkey with no key returns vk=0."""
        mods, vk = _parse_hotkey("Ctrl+Alt")
        self.assertEqual(vk, 0)

    def test_parse_invalid_empty_string(self):
        """Test parsing empty string."""
        mods, vk = _parse_hotkey("")
        self.assertEqual(mods, 0)
        self.assertEqual(vk, 0)

    def test_validate_valid_hotkeys(self):
        """Test validation of valid hotkey strings."""
        valid_hotkeys = [
            "Ctrl+C",
            "Ctrl+Alt+C",
            "Shift+Win+A",
            "Control+Z",
            "Alt+Shift+F",
            "Win+B",
        ]
        for hotkey in valid_hotkeys:
            with self.subTest(hotkey=hotkey):
                self.assertTrue(validate_hotkey_string(hotkey))

    def test_validate_invalid_no_modifier(self):
        """Test validation fails when no modifier present."""
        invalid_hotkeys = [
            "C",
            "A+B",  # Two keys, no modifier
            "Ctrl",  # Only modifier
        ]
        for hotkey in invalid_hotkeys:
            with self.subTest(hotkey=hotkey):
                self.assertFalse(validate_hotkey_string(hotkey))

    def test_validate_invalid_multiple_keys(self):
        """Test validation fails with multiple keys."""
        invalid_hotkeys = [
            "Ctrl+A+B",
            "Ctrl+Alt+C+D",
        ]
        for hotkey in invalid_hotkeys:
            with self.subTest(hotkey=hotkey):
                self.assertFalse(validate_hotkey_string(hotkey))

    def test_validate_invalid_unknown_key(self):
        """Test validation fails with unknown key."""
        invalid_hotkeys = [
            "Ctrl+1",
            "Ctrl+F1",
            "Alt+Space",
            "Ctrl+@",
        ]
        for hotkey in invalid_hotkeys:
            with self.subTest(hotkey=hotkey):
                self.assertFalse(validate_hotkey_string(hotkey))

    def test_validate_empty_and_none(self):
        """Test validation of empty and None values."""
        self.assertFalse(validate_hotkey_string(""))
        self.assertFalse(validate_hotkey_string(None))

    def test_validate_whitespace_handling(self):
        """Test that whitespace is handled correctly."""
        self.assertTrue(validate_hotkey_string("Ctrl + C"))
        self.assertTrue(validate_hotkey_string(" Ctrl+Alt+C "))
        self.assertFalse(validate_hotkey_string("Ctrl+  +C"))


class TestCenteringLogic(unittest.TestCase):
    """Tests for window centering calculations."""

    def test_center_calculation_basic(self):
        """Test basic centering calculation."""
        screen_x, screen_y = 0, 0
        screen_w, screen_h = 1920, 1080
        window_w, window_h = 800, 600
        
        expected_x = screen_x + (screen_w - window_w) // 2
        expected_y = screen_y + (screen_h - window_h) // 2
        
        self.assertEqual(expected_x, 560)
        self.assertEqual(expected_y, 240)

    def test_center_calculation_with_offset(self):
        """Test centering with non-zero screen offset."""
        screen_x, screen_y = 100, 50
        screen_w, screen_h = 1920, 1080
        window_w, window_h = 800, 600
        
        expected_x = screen_x + (screen_w - window_w) // 2
        expected_y = screen_y + (screen_h - window_h) // 2
        
        self.assertEqual(expected_x, 660)
        self.assertEqual(expected_y, 290)

    def test_near_full_screen_detection(self):
        """Test detection of near-full-screen windows."""
        NEAR_FULL_RATIO = 0.90
        screen_w, screen_h = 1920, 1080
        
        # Window at 95% of screen width should be skipped
        window_w = int(screen_w * 0.95)
        window_h = 600
        self.assertTrue(window_w >= screen_w * NEAR_FULL_RATIO)
        
        # Window at 85% of screen width should not be skipped
        window_w = int(screen_w * 0.85)
        self.assertFalse(window_w >= screen_w * NEAR_FULL_RATIO)

    def test_ease_out_cubic_function(self):
        """Test the easing function for animations."""
        # Define locally to avoid Windows dependency
        def _ease_out_cubic(t: float) -> float:
            return 1.0 - (1.0 - t) ** 3
        
        # Start should be 0
        self.assertEqual(_ease_out_cubic(0.0), 0.0)
        
        # End should be 1
        self.assertEqual(_ease_out_cubic(1.0), 1.0)
        
        # Middle should be > 0.5 (ease out accelerates then decelerates)
        mid = _ease_out_cubic(0.5)
        self.assertGreater(mid, 0.5)
        self.assertLess(mid, 1.0)
        
        # Function should be monotonically increasing
        self.assertLess(_ease_out_cubic(0.25), _ease_out_cubic(0.5))
        self.assertLess(_ease_out_cubic(0.5), _ease_out_cubic(0.75))


if __name__ == "__main__":
    unittest.main()
