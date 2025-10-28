import streamlit as st
import textwrap
import io
import builtins
import traceback
from contextlib import redirect_stdout, redirect_stderr

# ------------------ App setup ------------------
st.set_page_config(page_title="Python Interactive – Tabs", layout="wide")
st.title("🧪 Python Practice – Interactive Tabs")

# ------------------ Execution sandbox ------------------
def run_user_code(src: str, stdin_payload: str):
    """Execute user code with a minimal, safe-ish namespace and fake stdin."""
    input_lines = stdin_payload.splitlines()

    def fake_input(prompt: str = ""):
        if prompt:
            print(prompt, end="")
        if input_lines:
            return input_lines.pop(0)
        raise EOFError("No more stdin lines available")

    safe_builtins = {
        k: getattr(builtins, k) for k in [
            "abs","all","any","bool","bytes","chr","complex","dict","dir","divmod","enumerate",
            "filter","float","format","frozenset","getattr","hasattr","hash","hex","id","int",
            "isinstance","issubclass","iter","len","list","map","max","min","next","object",
            "oct","ord","pow","print","range","repr","reversed","round","set","slice","sorted",
            "str","sum","tuple","type","vars","zip","Exception","ValueError","EOFError"
        ]
    }
    user_globals = {"__name__": "__main__", "__builtins__": safe_builtins, "input": fake_input}
    user_locals = {}

    out_io, err_io = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out_io), redirect_stderr(err_io):
            exec(src, user_globals, user_locals)
    except SystemExit as se:
        print(f"SystemExit: {se}", file=out_io)
    except Exception:
        traceback.print_exc(file=err_io)
    return out_io.getvalue(), err_io.getvalue()

# ------------------ Questions as data ------------------
QUESTIONS = [
    {
        "key": "grading",
        "tab": "📊 Grading Program",
        "problem": textwrap.dedent("""
        **Question 1: Grading Program**

        Write a code which takes the input as the score and prints the Grade.

        - A : 90 to 100
        - B : 80 to 89
        - C : 70 to 79
        - D : 60 to 69
        - E : 50 to 59
        - F : less than 50

        For scores greater than 100 or less than 0, print **Invalid**.
        """),
        "default_code": textwrap.dedent("""\
        # Read a single integer score from input() and print the grade
        # Example stdin:
        # 86
        try:
            score = int(input().strip())
            if score < 0 or score > 100:
                print("Invalid")
            elif score >= 90:
                print("A")
            elif score >= 80:
                print("B")
            elif score >= 70:
                print("C")
            elif score >= 60:
                print("D")
            elif score >= 50:
                print("E")
            else:
                print("F")
        except Exception:
            print("Invalid")
        """),
        "default_stdin": "86",
    },
    {
        "key": "leap",
        "tab": "🗓️ Leap Year",
        "problem": textwrap.dedent("""
        **Question 2: Leap Year**

        Write a program that reads a year and prints **Leap Year** if it is a leap year,
        otherwise print **Not Leap Year**.

        Rules (Gregorian):
        - If the year is divisible by 400 ⇒ Leap Year
        - Else if divisible by 100 ⇒ Not Leap Year
        - Else if divisible by 4 ⇒ Leap Year
        - Else ⇒ Not Leap Year
        """),
        "default_code": textwrap.dedent("""\
        # Read a year from input and print Leap Year / Not Leap Year
        # Example stdin:
        # 2024
        try:
            year = int(input().strip())
            if year % 400 == 0:
                print("Leap Year")
            elif year % 100 == 0:
                print("Not Leap Year")
            elif year % 4 == 0:
                print("Leap Year")
            else:
                print("Not Leap Year")
        except Exception:
            print("Invalid")
        """),
        "default_stdin": "2024",
    },
]

# Initialize per-question state
for q in QUESTIONS:
    st.session_state.setdefault(f"{q['key']}_code", q["default_code"])
    st.session_state.setdefault(f"{q['key']}_stdin", q["default_stdin"])
    st.session_state.setdefault(f"{q['key']}_out", ("", ""))
    st.session_state.setdefault(f"{q['key']}_changed", False)
    st.session_state.setdefault(f"{q['key']}_auto", False)

# ------------------ UI: Tabs ------------------
tabs = st.tabs([q["tab"] for q in QUESTIONS])

for q, tab in zip(QUESTIONS, tabs):
    with tab:
        st.header(q["tab"])
        st.markdown(q["problem"])
        st.divider()

        st.markdown("### ✍️ Code editor")
        st.caption("Type Python below. Click **Run**, or enable **Run on edit**. "
                   "`input()` reads from the stdin box.")

        def _mark_changed(key=q["key"]):
            st.session_state[f"{key}_changed"] = True

        st.session_state[f"{q['key']}_auto"] = st.toggle(
            "Run on edit (auto)", value=st.session_state[f"{q['key']}_auto"], key=f"{q['key']}_auto_toggle"
        )

        code = st.text_area(
            "Python code",
            value=st.session_state[f"{q['key']}_code"],
            height=320,
            label_visibility="collapsed",
            key=f"{q['key']}_code",
            on_change=_mark_changed
        )

        stdin_text = st.text_area(
            "Custom input (stdin)",
            value=st.session_state[f"{q['key']}_stdin"],
            height=80,
            help="Lines returned when your code calls input().",
            key=f"{q['key']}_stdin",
            on_change=_mark_changed
        )

        c1, c2, c3 = st.columns([1,1,1])
        run_clicked = c1.button("▶️ Run", key=f"{q['key']}_run")
        clear_clicked = c2.button("🧹 Clear output", key=f"{q['key']}_clear")
        reset_clicked = c3.button("↩️ Reset", key=f"{q['key']}_reset")

        if reset_clicked:
            st.session_state[f"{q['key']}_code"] = q["default_code"]
            st.session_state[f"{q['key']}_stdin"] = q["default_stdin"]
            st.session_state[f"{q['key']}_out"] = ("", "")
            st.session_state[f"{q['key']}_changed"] = False
            st.rerun()

        if clear_clicked:
            st.session_state[f"{q['key']}_out"] = ("", "")
            st.session_state[f"{q['key']}_changed"] = False

        should_run = run_clicked or (
            st.session_state[f"{q['key']}_auto"] and st.session_state.get(f"{q['key']}_changed", False)
        )
        if should_run:
            out, err = run_user_code(st.session_state[f"{q['key']}_code"], st.session_state[f"{q['key']}_stdin"])
            st.session_state[f"{q['key']}_out"] = (out, err)
            st.session_state[f"{q['key']}_changed"] = False

        st.markdown("### 🧪 Output")
        out, err = st.session_state[f"{q['key']}_out"]

        if out.strip():
            st.code(out, language="text")
        elif not err.strip():
            st.info("No output yet. Edit code or click **Run**.")

        if err.strip():
            st.error("Errors / Traceback")
            st.code(err, language="text")

st.caption("⚠️ Code executes locally in this Streamlit app. Avoid running untrusted code.")






# import streamlit as st
# import textwrap
# import io
# import builtins
# import traceback
# from contextlib import redirect_stdout, redirect_stderr

# # ------------------ App setup ------------------
# st.set_page_config(page_title="Python & Pandas Interactive – Slides", layout="wide")
# st.title("PYTHON & PANDAS INTERACTIVE – Slides")

# # ------------------ Execution sandbox ------------------
# def run_user_code(src: str, stdin_payload: str):
#     input_lines = stdin_payload.splitlines()

#     def fake_input(prompt: str = ""):
#         if prompt:
#             print(prompt, end="")
#         if input_lines:
#             return input_lines.pop(0)
#         raise EOFError("No more stdin lines available")

#     safe_builtins = {
#         k: getattr(builtins, k) for k in [
#             "abs","all","any","bool","bytes","chr","complex","dict","dir","divmod","enumerate",
#             "filter","float","format","frozenset","getattr","hasattr","hash","hex","id","int",
#             "isinstance","issubclass","iter","len","list","map","max","min","next","object",
#             "oct","ord","pow","print","range","repr","reversed","round","set","slice","sorted",
#             "str","sum","tuple","type","vars","zip","Exception","ValueError","EOFError"
#         ]
#     }
#     user_globals = {"__name__": "__main__", "__builtins__": safe_builtins, "input": fake_input}
#     user_locals = {}

#     out_io, err_io = io.StringIO(), io.StringIO()
#     try:
#         with redirect_stdout(out_io), redirect_stderr(err_io):
#             exec(src, user_globals, user_locals)
#     except SystemExit as se:
#         print(f"SystemExit: {se}", file=out_io)
#     except Exception:
#         traceback.print_exc(file=err_io)

#     return out_io.getvalue(), err_io.getvalue()

# # ------------------ Slides config ------------------
# SLIDES = [
#     {
#         "title": "Slide 1 — Grading Program",
#         "problem": textwrap.dedent("""
#         **Question 1: Grading Program**

#         Write a code which takes the input as the score and prints the Grade.

#         - A : 90 to 100
#         - B : 80 to 89
#         - C : 70 to 79
#         - D : 60 to 69
#         - E : 50 to 59
#         - F : less than 50

#         For scores greater than 100 or less than 0, print **Invalid**.
#         """),
#         "default_code": textwrap.dedent("""\
#         # Read a single integer score from input() and print the grade
#         # Example stdin:
#         # 86
#         try:
#             score = int(input().strip())

#             if score < 0 or score > 100:
#                 print("Invalid")
#             elif score >= 90:
#                 print("A")
#             elif score >= 80:
#                 print("B")
#             elif score >= 70:
#                 print("C")
#             elif score >= 60:
#                 print("D")
#             elif score >= 50:
#                 print("E")
#             else:
#                 print("F")
#         except Exception:
#             print("Invalid")
#         """),
#         "default_stdin": "86",
#     },
#     {
#         "title": "Slide 2 — Leap Year Program",
#         "problem": textwrap.dedent("""
#         **Question 2: Leap Year**

#         Write a program that reads a year and prints **Leap Year** if it is a leap year,
#         otherwise print **Not Leap Year**.

#         Rules (Gregorian):
#         - If the year is divisible by 400 ⇒ Leap Year
#         - Else if divisible by 100 ⇒ Not Leap Year
#         - Else if divisible by 4 ⇒ Leap Year
#         - Else ⇒ Not Leap Year
#         """),
#         "default_code": textwrap.dedent("""\
#         # Read a year from input and print Leap Year / Not Leap Year
#         # Example stdin:
#         # 2024
#         try:
#             year = int(input().strip())

#             if year % 400 == 0:
#                 print("Leap Year")
#             elif year % 100 == 0:
#                 print("Not Leap Year")
#             elif year % 4 == 0:
#                 print("Leap Year")
#             else:
#                 print("Not Leap Year")
#         except Exception:
#             print("Invalid")
#         """),
#         "default_stdin": "2024",
#     },
# ]

# # ------------------ Sidebar navigation ------------------
# slide_titles = [s["title"] for s in SLIDES]
# choice = st.sidebar.radio("Go to slide:", slide_titles, index=0)
# slide_idx = slide_titles.index(choice)
# slide = SLIDES[slide_idx]

# # Unique keys per slide so each keeps its own editor/output
# K = f"slide{slide_idx}"

# # Initialize state
# st.session_state.setdefault(f"{K}_code", slide["default_code"])
# st.session_state.setdefault(f"{K}_stdin", slide["default_stdin"])
# st.session_state.setdefault(f"{K}_last_output", ("", ""))
# st.session_state.setdefault(f"{K}_changed", False)

# # ------------------ Slide content ------------------
# st.header(slide["title"])
# st.markdown(slide["problem"])
# st.divider()

# st.markdown("### ✍️ Code editor")
# st.caption("Type Python below. Click **Run** to execute. `input()` reads from the stdin box.")

# def _mark_changed():
#     st.session_state[f"{K}_changed"] = True

# auto = st.checkbox("Run on edit (auto)", value=False, key=f"{K}_auto")

# code = st.text_area(
#     "Python code",
#     value=st.session_state[f"{K}_code"],
#     height=330,
#     label_visibility="collapsed",
#     key=f"{K}_code",
#     on_change=_mark_changed
# )

# stdin_text = st.text_area(
#     "Custom input (stdin)",
#     value=st.session_state[f"{K}_stdin"],
#     height=80,
#     help="Lines returned when your code calls input().",
#     key=f"{K}_stdin",
#     on_change=_mark_changed
# )

# c1, c2, c3 = st.columns([1,1,1])
# run_clicked = c1.button("▶️ Run", key=f"{K}_run")
# clear_clicked = c2.button("🧹 Clear output", key=f"{K}_clear")
# reset_clicked = c3.button("↩️ Reset to starter", key=f"{K}_reset")

# # Actions
# if reset_clicked:
#     st.session_state[f"{K}_code"] = slide["default_code"]
#     st.session_state[f"{K}_stdin"] = slide["default_stdin"]
#     st.session_state[f"{K}_last_output"] = ("", "")
#     st.session_state[f"{K}_changed"] = False
#     st.experimental_rerun()

# if clear_clicked:
#     st.session_state[f"{K}_last_output"] = ("", "")
#     st.session_state[f"{K}_changed"] = False

# should_run = run_clicked or (auto and st.session_state.get(f"{K}_changed", False))
# if should_run:
#     out, err = run_user_code(st.session_state[f"{K}_code"], st.session_state[f"{K}_stdin"])
#     st.session_state[f"{K}_last_output"] = (out, err)
#     st.session_state[f"{K}_changed"] = False

# # ------------------ Output ------------------
# st.markdown("### 🧪 Output")
# out, err = st.session_state[f"{K}_last_output"]

# if out.strip():
#     st.code(out, language="text")
# elif not err.strip():
#     st.info("No output yet. Edit code or click **Run**.")

# if err.strip():
#     st.error("Errors / Traceback")
#     st.code(err, language="text")

# st.caption("⚠️ Executes locally in this Streamlit app. Avoid running untrusted code.")






# import streamlit as st
# import textwrap
# import io
# import builtins
# import traceback
# from contextlib import redirect_stdout, redirect_stderr

# # ------------------ App setup ------------------
# st.set_page_config(page_title="Python & Pandas Interactive – Grading Kata", layout="wide")
# st.title("PYTHON & PANDAS INTERACTIVE")

# # ------------------ Problem text ------------------
# problem = textwrap.dedent("""
# **Question 1: Grading Program**

# Write a code which takes the input as the score and prints the Grade.

# - A : 90 to 100
# - B : 80 to 89
# - C : 70 to 79
# - D : 60 to 69
# - E : 50 to 59
# - F : less than 50

# For scores greater than 100 or less than 0, print **Invalid**.
# """)
# st.markdown(problem)
# st.divider()

# st.markdown("### ✍️ Code editor")
# st.caption("Type Python below. Click **Run** to execute. `input()` will read from the “Custom input (stdin)” box.")

# # ------------------ Default starter code ------------------
# default_code = textwrap.dedent("""\
# # Read a single integer score from input() and print the grade
# # Example stdin:
# # 86
# try:
#     score = int(input().strip())

#     if score < 0 or score > 100:
#         print("Invalid")
#     elif score >= 90:
#         print("A")
#     elif score >= 80:
#         print("B")
#     elif score >= 70:
#         print("C")
#     elif score >= 60:
#         print("D")
#     elif score >= 50:
#         print("E")
#     else:
#         print("F")
# except Exception:
#     print("Invalid")
# """)

# # ------------------ Session state ------------------
# if "last_output" not in st.session_state:
#     st.session_state.last_output = ("", "")
# if "code" not in st.session_state:
#     st.session_state.code = default_code
# if "stdin_text" not in st.session_state:
#     st.session_state.stdin_text = "86"
# if "_code_changed" not in st.session_state:
#     st.session_state._code_changed = False

# # ------------------ Controls ------------------
# auto = st.checkbox("Run on edit (auto)", value=False, help="Run the code automatically whenever you edit it.")

# def _mark_changed():
#     st.session_state._code_changed = True

# code = st.text_area(
#     "Python code",
#     value=st.session_state.code,
#     height=350,
#     label_visibility="collapsed",
#     key="code",
#     on_change=_mark_changed
# )

# stdin_text = st.text_area(
#     "Custom input (stdin)",
#     value=st.session_state.stdin_text,
#     height=80,
#     help="Lines returned to your code when it calls input().",
#     key="stdin_text",
#     on_change=_mark_changed
# )

# col1, col2, col3 = st.columns([1,1,1])
# run_clicked = col1.button("▶️ Run")
# clear_clicked = col2.button("🧹 Clear output")
# reset_clicked = col3.button("↩️ Reset to starter")

# # ------------------ Execution sandbox ------------------
# def run_user_code(src: str, stdin_payload: str):
#     input_lines = stdin_payload.splitlines()

#     def fake_input(prompt: str = ""):
#         if prompt:
#             print(prompt, end="")
#         if input_lines:
#             return input_lines.pop(0)
#         raise EOFError("No more stdin lines available")

#     # Safe-ish builtins (no __import__)
#     safe_builtins = {
#         k: getattr(builtins, k) for k in [
#             "abs","all","any","bool","bytes","chr","complex","dict","dir","divmod","enumerate",
#             "filter","float","format","frozenset","getattr","hasattr","hash","hex","id","int",
#             "isinstance","issubclass","iter","len","list","map","max","min","next","object",
#             "oct","ord","pow","print","range","repr","reversed","round","set","slice","sorted",
#             "str","sum","tuple","type","vars","zip","Exception","ValueError","EOFError"
#         ]
#     }

#     user_globals = {"__name__": "__main__", "__builtins__": safe_builtins, "input": fake_input}
#     user_locals = {}

#     out_io, err_io = io.StringIO(), io.StringIO()
#     try:
#         with redirect_stdout(out_io), redirect_stderr(err_io):
#             exec(src, user_globals, user_locals)
#     except SystemExit as se:
#         print(f"SystemExit: {se}", file=out_io)
#     except Exception:
#         traceback.print_exc(file=err_io)

#     return out_io.getvalue(), err_io.getvalue()

# # ------------------ Run conditions ------------------
# should_run = run_clicked or (auto and st.session_state._code_changed)

# if reset_clicked:
#     st.session_state.code = default_code
#     st.session_state.stdin_text = "86"
#     st.session_state.last_output = ("", "")
#     st.session_state._code_changed = False
#     st.experimental_rerun()

# if clear_clicked:
#     st.session_state.last_output = ("", "")
#     st.session_state._code_changed = False

# if should_run:
#     out, err = run_user_code(st.session_state.code, st.session_state.stdin_text)
#     st.session_state.last_output = (out, err)
#     st.session_state._code_changed = False

# # ------------------ Output ------------------
# st.markdown("### 🧪 Output")
# out, err = st.session_state.last_output

# if out.strip():
#     st.code(out, language="text")
# elif not err.strip():
#     st.info("No output yet. Edit code or click **Run**.")

# if err.strip():
#     st.error("Errors / Traceback")
#     st.code(err, language="text")

# st.caption("⚠️ Executes locally in this Streamlit app. Avoid running untrusted code.")
