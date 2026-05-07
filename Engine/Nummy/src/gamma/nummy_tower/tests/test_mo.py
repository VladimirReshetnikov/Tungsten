import unittest

from nummy_tower import compute_mo_1010101010_1010


class TestMathOverflow1010101010_1010(unittest.TestCase):
    def test_tail_prefix_and_zeros(self) -> None:
        desc = compute_mo_1010101010_1010(precision=120, frac_digits=10)
        self.assertEqual(desc.zeros_between, 9_999_999_987)
        self.assertEqual(desc.tail_string, "2811012357389.4407116278")


if __name__ == "__main__":
    unittest.main()
