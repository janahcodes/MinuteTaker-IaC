"""Pull action items out of a meeting transcript.

Rule-based on purpose: it runs on a CPU-only worker with no API key and its
behaviour is easy to explain and test. It looks for commitment and request
phrasing ("I'll send…", "can you…", "we need to…") and for deadlines.
"""
from __future__ import annotations

import calendar
import re
from datetime import date, timedelta

# Phrases that usually mark a task being taken on or handed out.
_COMMITMENT = re.compile(
    r"""\b(
        i['’]ll | i\ will | i['’]m\ going\ to | i\ can\ take |
        we['’]ll | we\ will | we\ need\ to | we\ should | we\ have\ to | we\ must |
        let['’]?s | can\ you | could\ you | would\ you | will\ you | please |
        you\ need\ to | make\ sure | action\ item | to-?do | follow\ up | follow-up |
        assign(?:ed)?\ to | is\ going\ to | needs?\ to | by\ (?:the\ )?end\ of
        | is\ due | are\ due | due\ (?:by|on|before) | homework | assignment | deadline
    )\b""",
    re.IGNORECASE | re.VERBOSE,
)

_DUE = re.compile(
    r"""\b(
        (?:by|before|on|until|due)\s+
        (?:the\s+)?
        (?:end\ of\ (?:the\ )?(?:day|week|month|quarter|sprint)
          | (?:next\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|week|month)
          | tomorrow | tonight | today | eod | eow
          | (?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?
          | \d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*
          | \d{1,2}(?::\d{2})?\s*(?:am|pm)
        )
        | tomorrow | next\ week | this\ week | end\ of\ (?:the\ )?(?:day|week|month)
    )\b""",
    re.IGNORECASE | re.VERBOSE,
)

# "Sarah, can you…" / "Sarah will…" -> owner "Sarah"
_OWNER = re.compile(
    r"^(?:ok(?:ay)?|so|and|alright|right)?[,\s]*([A-Z][a-z]+)"
    # "Sarah, can you…" / "Sarah, please…" — a bare "Now, …" is not a name
    r"(?:,\s+(?:can|could|would|will)\s+you\b|,\s+please\b|,\s+you\s+(?:need|should|have)\s+to\b"
    r"|\s+(?:will|can|could|is going to|needs to|should)\b)"
)
_NOT_NAMES = {"I", "We", "You", "Let", "Lets", "Can", "Could", "Would", "Will", "Please",
              "The", "This", "That", "And", "So", "Okay", "Ok", "Alright", "Right", "Make", "Next",
              "It", "He", "She", "They", "There", "Who", "What", "Someone", "Everyone", "Nobody",
              "Now", "Also", "Basically", "Today", "Then", "Here", "Actually", "Well", "Yes", "No", "Thanks", "This"}

_SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")
# Filler questions that match the patterns but aren't tasks.
_IGNORE = re.compile(r"^(can you (hear|see) me|could you repeat|would you like)", re.IGNORECASE)


def split_sentences(segments: list[dict]) -> list[tuple[float, str]]:
    """Join Whisper segments into sentences, keeping each sentence's start time."""
    out: list[tuple[float, str]] = []
    buf, start = "", None
    for seg in segments:
        for piece in _SENTENCE_SPLIT.split(seg["text"].strip()):
            if not piece:
                continue
            if start is None:
                start = seg["start"]
            buf = f"{buf} {piece}".strip()
            if buf[-1:] in ".!?":
                out.append((start, buf))
                buf, start = "", None
    if buf:
        out.append((start or 0.0, buf))
    return out


def extract_action_items(segments: list[dict], limit: int = 25, ref: date | None = None) -> list[dict]:
    """ref is the day the meeting happened; relative deadlines are resolved against it."""
    items: list[dict] = []
    seen: set[str] = set()
    for start, sentence in split_sentences(segments):
        if len(sentence.split()) < 4 or _IGNORE.search(sentence):
            continue
        named = _OWNER.match(sentence)
        named = named if named and named.group(1) not in _NOT_NAMES else None
        # "Mike will set up…" has no commitment phrase but names an owner.
        if not (_COMMITMENT.search(sentence) or named):
            continue
        key = sentence.lower()
        if key in seen:
            continue
        seen.add(key)

        due = _DUE.search(sentence)
        owner = None
        if named:
            owner = named.group(1)
        elif re.match(r"^(?:\w+[.,]\s*)?(i['’]ll|i will|i['’]m going to|i can take)\b", sentence, re.IGNORECASE):
            owner = "Speaker"

        due_phrase = due.group(0) if due else None
        due_date = resolve_due(due_phrase, ref) if (due_phrase and ref) else None
        items.append({
            "text": sentence,
            "task": task_title(sentence, due_phrase),
            "start": round(float(start), 1),
            "owner": owner,
            "due": due_phrase,
            "due_date": due_date.isoformat() if due_date else None,
        })
        if len(items) >= limit:
            break
    return items


# ---------------------------------------------------------------------------
# Deadlines -> calendar dates
# ---------------------------------------------------------------------------
_WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
_MONTHS = {m.lower(): i for i, m in enumerate(calendar.month_abbr) if m}
_MONTHS["sept"] = 9


def _next_weekday(ref: date, wd: int) -> date:
    """The next given weekday strictly after ref ("by Friday" said on a Friday = next Friday)."""
    ahead = (wd - ref.weekday()) % 7 or 7
    return ref + timedelta(days=ahead)


def resolve_due(phrase: str | None, ref: date) -> date | None:
    """Turn "by Friday", "tomorrow", "end of week", "Nov 20" ... into a date, relative to ref."""
    if not phrase:
        return None
    p = re.sub(r"^(by|before|on|until|due)\s+", "", phrase.lower().strip())
    p = re.sub(r"^the\s+", "", p).replace(".", "")

    if p in {"today", "tonight", "eod", "end of day", "end of the day"} or re.fullmatch(r"\d{1,2}(:\d{2})?\s*(am|pm)", p):
        return ref
    if p == "tomorrow":
        return ref + timedelta(days=1)
    if p in {"end of week", "end of the week", "eow", "this week"}:
        return ref + timedelta(days=(4 - ref.weekday()) % 7)  # this Friday (or today if Friday)
    if p == "next week":
        return ref + timedelta(days=7 - ref.weekday())  # next Monday
    if p in {"end of month", "end of the month"}:
        return ref.replace(day=calendar.monthrange(ref.year, ref.month)[1])
    if p == "next month":
        return (ref.replace(day=1) + timedelta(days=32)).replace(day=1)
    if p in {"end of quarter", "end of the quarter"}:
        q_end = ((ref.month - 1) // 3 + 1) * 3
        return date(ref.year, q_end, calendar.monthrange(ref.year, q_end)[1])

    m = re.fullmatch(r"(next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)", p)
    if m:
        d = _next_weekday(ref, _WEEKDAYS.index(m.group(2)))
        # "next Friday" said early in a week means the Friday of the following week.
        if m.group(1) and d.isocalendar()[1] == ref.isocalendar()[1]:
            d += timedelta(days=7)
        return d

    m = re.fullmatch(r"([a-z]+)\s+(\d{1,2})(st|nd|rd|th)?", p) or None
    if m and m.group(1)[:4] in _MONTHS or (m and m.group(1)[:3] in _MONTHS):
        month = _MONTHS.get(m.group(1)[:4]) or _MONTHS[m.group(1)[:3]]
        return _future(ref, month, int(m.group(2)))
    m = re.fullmatch(r"(\d{1,2})(st|nd|rd|th)?\s+(of\s+)?([a-z]+)", p)
    if m and m.group(4)[:3] in _MONTHS:
        return _future(ref, _MONTHS[m.group(4)[:3]], int(m.group(1)))
    return None


def _future(ref: date, month: int, day: int) -> date | None:
    try:
        d = date(ref.year, month, day)
    except ValueError:
        return None
    return d if d >= ref else date(ref.year + 1, month, day)


# ---------------------------------------------------------------------------
# "Sarah, can you send the proposal by Friday?" -> "Send the proposal"
# ---------------------------------------------------------------------------
_LEAD = re.compile(
    r"""^(?:(?:ok(?:ay)?|so|and|alright|right|um|uh)[,\s]+)*
        (?:[A-Z][a-z]+,?\s+)?                                   # owner name
        (?:can\ you|could\ you|would\ you|will\ you|please|
           i['’]ll|i\ will|i['’]m\ going\ to|i\ can\ take|
           we['’]ll|we\ will|we\ need\ to|we\ should|we\ have\ to|we\ must|
           you\ need\ to|let['’]?s|will|is\ going\ to|needs?\ to|should|can|could)\s+
        (?:also\s+|please\s+|just\s+)?""",
    re.IGNORECASE | re.VERBOSE,
)


def task_title(sentence: str, due_phrase: str | None = None, max_words: int = 12) -> str:
    t = sentence.strip()
    if due_phrase:
        t = re.sub(r"\s*" + re.escape(due_phrase), "", t, flags=re.IGNORECASE)
    t = re.sub(r"^(?:also|and|plus|for (?:homework|next time|next class))[,\s]+", "", t, flags=re.IGNORECASE)
    t = _LEAD.sub("", t, count=1)
    t = re.sub(r"\s+(?:is|are)\s+due$", "", t.rstrip(" .!?"), flags=re.IGNORECASE)
    t = re.sub(r"[\s,;:.!?]+$", "", t)
    words = t.split()
    if len(words) > max_words:
        t = " ".join(words[:max_words]) + "…"
    return t[:1].upper() + t[1:] if t else sentence
