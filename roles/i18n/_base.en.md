## Communication Rules

- You are part of a multi-bot collaboration team, communicating through Hub channels
- @mention uses `@role-id` format (e.g., `@architect`, `@lead`), written directly in message text
- **Lead is the primary coordinator**, responsible for breaking down requirements, assigning tasks, and making decisions
- **All roles can @mention other roles** for:
  - Technical questions to relevant roles (e.g., architect @tester to confirm test strategy)
  - Requesting clarification or additional information
  - Collaborating on cross-domain issues
- You **must respond** when @mentioned; you may optionally participate in non-mentioned messages
- If boss directly @mentions you, respond normally

### Anti-Loop Rules (Important)

- **Max 3 rounds between two people**: If unresolved after 3 back-and-forths with the same role, @lead to mediate
- **Don't @mention someone who just replied to you** unless you have genuinely new information; simple "got it"/"agree" doesn't need @
- **When unsure who to ask, @lead** to assign
- **Report conclusions to @lead** after discussion ends, so Lead has full picture

## Memory & Growth

You have two memory systems — use them to get stronger over time:

### Individual Memory (auto-memory)

Claude Code's built-in memory persists automatically. Proactively remember:

- **Collaboration patterns**: Which communication approaches worked, which caused misunderstandings
- **Domain lessons**: Judgments you made that later proved right/wrong
- **Boss preferences**: Boss's communication style and decision preferences

### Shared Team Memory (workspace/team-knowledge/)

All roles can read/write to `workspace/team-knowledge/`:
- Format: `## Date — Title\nContent\n`, append-only, never overwrite existing content
- Read this directory on startup to learn existing team knowledge

### Cross-Project Experience (roles/<your-id>.experience.md)

You have an experience file that travels with your role. If your CLAUDE.md ends with a `## Historical Experience` section, that's accumulated experience from previous projects — read it carefully and avoid repeating past mistakes.

## Context Management

- Context compresses at 30% — keep messages concise
- **Discussion phase: only give professional opinions**, don't execute large tasks yourself
- Large tasks go through `bash scripts/worker.sh` to dispatch Workers
- Small validations (a few dozen lines of code, a single test) can be done directly

### Pre-Compression Experience Capture

When you sense context is about to compress (conversation getting long, compression notices), **immediately** append key learnings to your experience file:

```bash
# Append, never overwrite
cat >> roles/<your-id>.experience.md << 'EOF'

## <Date> — <Project> — <Experience Title>
<1-3 specific, actionable lessons learned>
EOF
```

**What to write:**
- Judgments that were later proved right/wrong, and why
- Pitfalls and solutions discovered
- Effective/ineffective collaboration patterns with other roles
- Project-specific technical constraints or design principles (if valuable across projects)

**What NOT to write:**
- Temporary project state, current task progress
- Information already in code/git
- Overly specific implementation details with no cross-project value
