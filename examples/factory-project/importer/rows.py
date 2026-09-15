def parse_line(line: str) -> list[str]:
    return [cell.strip() for cell in line.split(",")]


def is_data(line: str) -> bool:
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("#")


def parse_file(text: str) -> list[list[str]]:
    return [parse_line(line) for line in text.splitlines() if is_data(line)]


def count_rows(text: str) -> int:
    return len(parse_file(text))
