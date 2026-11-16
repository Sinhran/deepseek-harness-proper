# Product

## Register

product

## Users

macOS developers and technical users running a local DeepSeek coding agent.
They work inside a chosen workspace folder, asking the agent to read, write,
and run code. They are in flow, glancing between chat, diffs, and terminal
output. They use the keyboard heavily and expect standard macOS behavior.

## Product Purpose

DeepSeek Harness (Proper) is a native macOS chat front end for the DeepSeek
API agent loop. One window, three panes: sessions sidebar, conversation with
composer, inspector with Preview, Review, Terminal, and Trace. The agent
streams text and reasoning, calls tools behind approval gates, edits files,
and every change is previewable and reviewable. Success is a trustworthy
working session: the user always knows what the agent did, and can undo,
open, or re-run anything.

## Brand Personality

Quiet, expert, precise. Chrome recedes, content leads. Warm ink on warm
paper, one blue accent that means action. Familiar before novel: standard
navigation, standard controls, no invented affordances.

## Anti-references

Not a neon-gradient AI chatbot landing page. Not glassmorphism panels or
gradient text. Not a hero-metric SaaS dashboard. Not a cold gray Linear
clone. No side-stripe accent borders, no identical icon-card grids, no modal
as first thought, no decorative motion, no display fonts in labels or data.

## Design Principles

1. Content leads, chrome recedes. The transcript and the diff are the product; everything else is quiet.
2. Earned familiarity. Use the control macOS users already know; invent nothing for flavor.
3. Every agent action is inspectable. Reasoning, tool input/output, terminal, and trajectory are one click away.
4. Quiet until needed. Empty states teach, approvals interrupt only when required, status appears only while working.
5. Keyboard-first, pointer-complete. Full keyboard paths with visible focus; every action also clickable with tooltips.

## Accessibility & Inclusion

WCAG 2.2 AA for text contrast. Visible keyboard focus on every interactive
element, never removed without a replacement. Respects
`accessibilityDisplayShouldReduceMotion` for loaders and spinners. Touch and
pointer targets follow macOS norms. No color-only meaning: status pairs
color with text or icon.
