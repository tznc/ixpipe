# Excluded by default; each needs a release built with the host's playwright
# feature and a display (see AGENTS.md and .claude/skills/app-qa):
#   mix test --only playwright   end-to-end tests (test/e2e)
#   mix test --only qa           screenshot QA (test/qa)
#   mix test --only chaos        the seeded monkey (test/qa/chaos_test.exs)
ExUnit.start(exclude: [:playwright, :qa, :chaos])
