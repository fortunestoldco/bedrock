import pytest
import ast
import os
import codecs
import re

def check_syntax(file_path):
    with open(file_path, "r") as file:
        source = file.read()
    try:
        ast.parse(source)
        return True
    except SyntaxError:
        return False

def test_main_syntax():
    assert check_syntax("main.py"), "Syntax error in main.py"

def test_flows_syntax():
    assert check_syntax("flows.py"), "Syntax error in flows.py"

def test_iam_syntax():
    assert check_syntax("iam.py"), "Syntax error in iam.py"

def test_manuscript_syntax():
    assert check_syntax("manuscript.py"), "Syntax error in manuscript.py"

def test_research_syntax():
    assert check_syntax("research.py"), "Syntax error in research.py"

def test_config_syntax():
    assert check_syntax("config.py"), "Syntax error in config.py"

def test_dynamo_syntax():
    assert check_syntax("dynamo.py"), "Syntax error in dynamo.py"

def check_escape_sequences(file_path):
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            content = file.read()
        
        # List of valid escape sequences in Python
        valid_escapes = [
            r'\\', r'\a', r'\b', r'\f', r'\n', r'\r', r'\t', r'\v',
            r'\N{', r'\u', r'\U', r'\x'
        ]
        
        # Find all escape sequences in the file
        escapes = re.findall(r'\\[^\\](?:[^\\\s])*', content)
        
        # Check each escape sequence
        for escape in escapes:
            # Skip if it's a valid escape sequence
            if any(escape.startswith(valid) for valid in valid_escapes):
                continue
            # Skip if it's inside a raw string (r"..." or r'...')
            if re.search(r'r["\'].*' + re.escape(escape) + r'.*["\']', content):
                continue
            return False
        return True
            
    except UnicodeDecodeError:
        return False

def check_file_encoding(file_path):
    try:
        # Try to detect BOM
        with open(file_path, 'rb') as file:
            raw = file.read(4)
            if raw.startswith(codecs.BOM_UTF8):
                return False
        return True
    except Exception:
        return False

def test_escape_sequences():
    python_files = ["main.py", "flows.py", "iam.py", "manuscript.py", 
                    "research.py", "config.py", "dynamo.py"]
    for file in python_files:
        assert check_escape_sequences(file), f"Invalid escape sequence found in {file}"
        assert check_file_encoding(file), f"Invalid file encoding or BOM found in {file}"
