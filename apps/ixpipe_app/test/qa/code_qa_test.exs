defmodule IxpipeApp.QA.CodeTest do
  # Screenshot QA of the Code tab: the sandboxed Python tool's code editor,
  # its log after a run, a failing script's callout and traceback, and the
  # Script tool's runtime line. Open each PNG and check every claim (see
  # .claude/skills/app-qa).
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :qa

  setup do
    qa = QA.launch!(open: "sales.yaml")
    on_exit(fn -> QA.stop(qa) end)
    qa
  end

  defp python(page, lines) do
    Playwright.click(page, role: "tab", name: "Code tab")
    Playwright.click(page, "Add python")
    Playwright.click(page, "Connect from orders")
    Playwright.click(page, "Connect to python_1 in")

    for {line, i} <- Enum.with_index(lines, 1) do
      if i > 1, do: Playwright.click(page, "Add a line")
      assert :ok = Playwright.await(page, role: "textbox", name: "Script line #{i}")
      Playwright.fill(page, "Script line #{i}", line)
    end
  end

  test "the Code tab and the code editor", %{page: page} do
    python(page, [
      "print('orders:', len(inputs['in']))",
      "output = [{'id': r['id'], 'twice': r['amount'] * 2}",
      "          for r in inputs['in']]"
    ])

    assert Playwright.input_value(page, "Script line 3") == "          for r in inputs['in']]"

    QA.capture(page, "code-01-editor", [
      "The ribbon's Code tab is selected, its group holding 'Python' and 'Script' with icons",
      "The right panel shows 'Script' with three numbered rows of monospace code on a grey box, indentation kept",
      "Below it, an 'Add a line' button, then Row limit, Time limit and Memory limit inputs"
    ])
  end

  test "a run shows the table, and the log of what it printed", %{page: page} do
    python(page, [
      "print('orders:', len(inputs['in']))",
      "output = [{'id': r['id'], 'twice': r['amount'] * 2} for r in inputs['in']]"
    ])

    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "Run succeeded")
    Playwright.click(page, "Show log output")
    assert :ok = Playwright.await_text(page, "orders: 4")

    QA.capture(page, "code-02-log", [
      "The python_1 card shows out and log row pills; a green 'Run succeeded' callout bottom-left",
      "Results has out and log toggles, log selected, listing stream 'stdout' and line 'orders: 4'"
    ])
  end

  test "a failing script: the callout says what happened, Results the traceback", %{page: page} do
    python(page, ["x = 1", "output = x / 0"])
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "python_1 failed.")

    QA.capture(page, "code-03-error", [
      "A red-tinted callout bottom-left titled 'python_1 failed.' reading 'Python raised ZeroDivisionError on line 2: division by zero. Fix the script and run again.'",
      "Results, under the canvas, shows the traceback in monospace, naming script.py line 2",
      "The callout holds no traceback; nothing in the layout moved"
    ])
  end

  test "Script names the runtime it will use, or what's missing", %{page: page} do
    Playwright.click(page, role: "tab", name: "Code tab")
    Playwright.click(page, "Add script")
    assert :ok = Playwright.await(page, role: "textbox", name: "Interpreter")
    Playwright.fill(page, "Interpreter", "/nowhere/python3")
    assert :ok = Playwright.await_text(page, "Python can't run here.")

    QA.capture(page, "code-04-runtime", [
      "The right panel, titled script_1 / Script, opens with an amber callout 'Python can't run here.'",
      "It reads 'Python isn't installed at /nowhere/python3. Install it, or set Interpreter to a Python 3 executable.'",
      "Language choices python, javascript, ruby, php with python highlighted in teal"
    ])
  end
end
