import pytest
import ast
import os

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
