# Specification

<!--
  Replace this with your project's technical specification.

  Describe:
  - Tech stack (language, framework, database, etc.)
  - Architecture (monolith, microservices, CLI, web app, etc.)
  - Features (prioritized list — what to build first)
  - Data model (if applicable)
  - API design (if applicable)
  - Testing strategy
  - Deployment target

  Features should be prioritized. The agent builds them in order.
  Mark features as:
  - [ ] Not started
  - [~] In progress
  - [x] Complete

  Example:

  ## Tech Stack
  - Language: TypeScript
  - Runtime: Node.js
  - Storage: Local markdown files
  - Testing: Vitest

  ## Architecture
  CLI tool using Commander.js. Single entry point, command pattern.
  Data stored in .tasks/ directory as markdown files.

  ## Features (Priority Order)
  - [ ] `tf add <title>` — Create a task
  - [ ] `tf list` — Show all tasks
  - [ ] `tf done <id>` — Mark task complete
  - [ ] `tf list --project <name>` — Filter by project
  - [ ] `tf priority <id> <high|medium|low>` — Set priority
  - [ ] `tf search <query>` — Full-text search

  ## Data Model
  Each task is a markdown file: `.tasks/<id>.md`
  Frontmatter: title, status, priority, created, project

  ## Testing
  Unit tests for core logic. Integration tests for CLI commands.
  Target: >85% coverage.
-->
