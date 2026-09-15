from importer.rows import count_rows, parse_line


def test_parse_line_strips_cells():
    assert parse_line(" a , b ") == ["a", "b"]


def test_count_rows_ignores_blank_lines():
    assert count_rows("a,b\n\nc,d\n") == 2


def test_count_rows_ignores_comment_lines():
    assert count_rows("a,b\n# note\nc,d\n") == 2
