# Style

We write code to be read. Clarity beats cleverness. Simple beats clever. The next person reading this code — including yourself six months from now — should understand it without needing context.

No unnecessary abstractions, no premature generalization, no over-engineering. Add complexity only when the problem genuinely demands it.

---

## Ruby / Rails

### Layers

We keep a clear separation of concerns across three layers:

- **Controllers** — thin. Handle only request/response: authenticate, permit params, call a service, respond.
- **Models** — thin. Data, associations, validations, scopes, and simple query methods. No business logic.
- **Service objects** — domain logic lives here. One service per operation, named after what it does.

This separation gives clear visibility into what the application does, makes each piece independently testable, and scales well as the codebase grows.

```ruby
# Bad — business logic in the controller
class ImportsController < ApplicationController
  def create
    rows = CSV.parse(params[:file].read)
    rows.each do |row|
      Transaction.create!(date: row[0], amount: row[1], description: row[2])
    end
    redirect_to transactions_path
  end
end

# Bad — business logic in the model
class Transaction < ApplicationRecord
  def self.import_csv(file)
    CSV.parse(file.read).each do |row|
      create!(date: row[0], amount: row[1], description: row[2])
    end
  end
end

# Good — controller delegates to a service object
class ImportsController < ApplicationController
  def create
    result = ImportTransactions.new(params[:file], current_account).call
    redirect_to transactions_path, notice: "Imported #{result.count} transactions"
  end
end
```

### Service objects

Name service objects after the action they perform, not the thing they operate on. Use a single public method (`call`). Keep them focused — one responsibility per service.

```ruby
# app/services/import_transactions.rb
class ImportTransactions
  def initialize(file, account)
    @file = file
    @account = account
  end

  def call
    rows = parse_csv
    rows.map { |row| persist(row) }.compact
  end

  private
    def parse_csv
      CSV.parse(@file.read, headers: true)
    end

    def persist(row)
      @account.transactions.create(
        transaction_date: row["date"],
        amount: row["amount"],
        description: row["description"]
      )
    end
end
```

### Conditional returns

Prefer expanded conditionals over guard clauses. Guard clauses at the very top of a method are fine when the main body is non-trivial.

```ruby
# Bad
def process(file)
  return unless file.present?
  run_import(file)
end

# Good
def process(file)
  if file.present?
    run_import(file)
  end
end

# Fine — guard at the top, non-trivial body follows
def after_import(result)
  return if result.empty?

  notify_user(result)
  schedule_categorization(result)
  update_dashboard_cache
end
```

### Method ordering

1. Class methods
2. Public instance methods (`initialize` first)
3. Private methods

### Invocation order

Order private methods in the order they are called. The reader should follow the flow top-to-bottom.

### Visibility modifiers

No blank line after `private`. Indent the methods beneath it.

```ruby
class SomeClass
  def public_method
    # ...
  end

  private
    def private_method_1
      # ...
    end

    def private_method_2
      # ...
    end
end
```

### Comments

Do not add comments to code. If a piece of code needs a comment to explain what it does, rewrite it until it does not.

```ruby
# Bad — the comment exists because the name is unclear
# Calculate the number of days since the account was created
def d
  (Date.today - created_at.to_date).to_i
end

# Good — self-explanatory
def days_since_created
  (Date.today - created_at.to_date).to_i
end
```

Comments that explain *why* a decision was made belong in commit messages, not in source files. A file does not carry history — git does.

---

### Bang methods

Only use `!` when there is a non-bang counterpart. Do not use `!` merely to signal importance.

```ruby
# Bad — no non-bang counterpart
def clear_cache!
  Cache.flush
end

# Good — save has a non-bang counterpart
record.save!
```

### CRUD controllers

Model actions as CRUD on resources. When an action doesn't map to a standard verb, introduce a new resource.

```ruby
# Bad
resources :transactions do
  post :categorize
  post :archive
end

# Good
resources :transactions do
  resource :categorization
  resource :archival
end
```

### Jobs

Shallow job classes. Domain logic lives in the service object, not the job.

```ruby
# Bad — job contains business logic
class CategorizeTransactionJob < ApplicationJob
  def perform(transaction_id)
    transaction = Transaction.find(transaction_id)
    category = SomeApi.suggest(transaction.description)
    transaction.update!(category: category)
  end
end

# Good — job delegates to a service
class CategorizeTransactionJob < ApplicationJob
  def perform(transaction)
    CategorizeTransaction.new(transaction).call
  end
end
```

---

## Testing

We use RSpec for all tests. Prefer clarity in test descriptions — a failing test should tell you exactly what broke and why.

### Quality tools

The following are pre-configured in the `webapp/` Rails app:

| Tool | Purpose |
|------|---------|
| `rspec-rails` | Test framework |
| `simplecov` | Code coverage (target: 90%+) |
| `rubocop-rails-omakase` | Code style linting |
| `reek` | Code smell detection |
| `brakeman` | Security vulnerability analysis |
| `bundler-audit` | Dependency vulnerability scanning |
| `bullet` | N+1 query detection |
| `capybara` | Browser/system tests |

### Coverage targets

| Layer | Target |
|-------|--------|
| Models | 90% |
| Service objects | 100% |
| Controllers | 80% |
| System tests | Critical paths only |

### Structure

```
spec/
  models/           # Model validations, associations, scopes
  services/         # Service object specs (the most important layer)
  requests/         # Controller/routing integration tests
  system/           # Capybara browser tests (full stack)
  support/          # Shared helpers, factories
```

### Service object specs

Service objects are the core of the domain logic. Test them thoroughly and directly.

```ruby
# spec/services/import_transactions_spec.rb
RSpec.describe ImportTransactions do
  describe "#call" do
    let(:account) { create(:account) }
    let(:file)    { fixture_file_upload("bank_export.csv") }

    it "imports all rows from the CSV" do
      result = described_class.new(file, account).call
      expect(result.count).to eq(3)
    end

    it "skips duplicate transactions" do
      described_class.new(file, account).call
      result = described_class.new(file, account).call
      expect(result.count).to eq(0)
    end
  end
end
```

### System tests

System tests use Capybara with a headless browser. They test the full Rails stack (no Tauri shell).

```ruby
# spec/system/imports_spec.rb
RSpec.describe "Importing transactions", type: :system do
  it "user imports a CSV and sees transactions" do
    visit imports_path
    attach_file "File", Rails.root.join("spec/fixtures/bank_export.csv")
    click_button "Import"
    expect(page).to have_text("Imported 3 transactions")
  end
end
```

### CI (GitHub Actions)

The kit ships with `.github/workflows/ci.yml` that runs on every push and pull request:

```
rspec          — full test suite
rubocop        — style checks
brakeman       — security audit
bundler-audit  — dependency vulnerabilities
```

Reek runs locally (`bundle exec reek`) but is not a CI gate — it generates discussion, not failures.

### Tauri E2E

Testing the Tauri shell (process management, port allocation, clean shutdown) is done manually — see the end-to-end checklist in each milestone. Tauri provides `tauri-driver` (WebDriver) for automated desktop E2E testing; this is documented as a future path but not included in the kit's CI.

---

## Rust

Rust has its own strong style conventions. Do not apply Ruby instincts here — they are different languages with different philosophies. The detailed Rust and Tauri guide lives in `desktop/CLAUDE.md` (added when the `desktop/` directory lands). The rules below apply across the whole project.

### Comments

Rust comments are **expected** — this is the opposite of the Ruby rule above. The community has three distinct layers, each with a job:

| Type | Syntax | Purpose |
|------|--------|---------|
| Doc comment | `///` | Required on every public item. Rendered by `rustdoc`. |
| Module doc | `//!` | Top of every module file. Explains what the module does. |
| Inline comment | `//` | Explains **why**, not what. Tricky logic, trade-off decisions. |
| Safety comment | `// Safety:` | Mandatory before every `unsafe` block. Non-negotiable. |

```rust
//! Manages the Rails server and Solid Queue worker processes.
//! Spawned at app start, supervised during runtime, killed on shutdown.

/// Finds the first available TCP port starting from `from`.
///
/// # Errors
/// Returns an error if no port is available in the search range.
pub fn find_available_port(from: u16) -> Result<u16> {
    (from..from + 100)
        .find(|&p| TcpListener::bind(("127.0.0.1", p)).is_ok())
        .ok_or(ProcessError::NoPortAvailable)
}

// Safety: ptr was obtained from Box::into_raw and we have exclusive
// ownership at this point — no other reference exists.
unsafe { Box::from_raw(ptr) }
```

Do not write comments that restate what the code does (`// increment the counter`). Write comments that explain why a decision was made, or why an obvious alternative was rejected.

### Readability over brevity

Rust can be written very concisely. Prefer readable over compact, especially in process management code where mistakes have real consequences.

```rust
// Bad — too terse
let port = (8934..9000).find(|p| TcpListener::bind(("127.0.0.1", *p)).is_ok()).unwrap();

// Good — clear intent
let port = find_available_port(8934)
    .expect("No available port found in range 8934–9000");
```

### Error handling

Define explicit typed errors with `thiserror`. Use `?` to propagate. Avoid `.unwrap()` in production paths — use `.expect("reason")` so failures are debuggable. Centralise error types in `src/error.rs`.

```rust
// src/error.rs
#[derive(Debug, thiserror::Error)]
pub enum ProcessError {
    #[error("Failed to spawn {name}: {source}")]
    SpawnFailed { name: String, #[source] source: io::Error },

    #[error("Process {name} exited unexpectedly")]
    UnexpectedExit { name: String },

    #[error("No TCP port available starting from {from}")]
    NoPortAvailable { from: u16 },
}

// In production code — propagate with ?
let contents = fs::read_to_string(&path)?;

// When propagation is impossible — explain the expectation
let contents = fs::read_to_string(&path)
    .expect("Failed to read config file at startup");
```

### Process management

Use `Option<Child>` so handles can be cleanly consumed on shutdown. Implement `Drop` for automatic cleanup — never rely on callers remembering to call a cleanup function. Use `tokio::sync::Mutex` (not `std::sync::Mutex`) when the lock is held across `.await` points.

```rust
struct ProcessManager {
    child: Option<tokio::process::Child>,
    port: u16,
}

impl ProcessManager {
    pub async fn stop(&mut self) -> Result<()> {
        let Some(mut child) = self.child.take() else {
            return Ok(());
        };
        child.start_kill()?;
        tokio::time::timeout(Duration::from_secs(5), child.wait()).await
            .map_err(|_| ProcessError::ShutdownTimeout)?;
        Ok(())
    }
}

impl Drop for ProcessManager {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            // Best-effort kill on drop — error ignored intentionally
            let _ = child.start_kill();
        }
    }
}
```

### Module structure

Split files by logical responsibility, not by line count. One clear responsibility per module. When a file grows past ~200 lines of meaningful code and contains distinct concepts, split it.

```
desktop/src/
├── lib.rs              ← entry point; declares modules only
├── error.rs            ← all error types
├── process/
│   ├── mod.rs          ← re-exports; or use process.rs + process/ dir
│   ├── manager.rs      ← ProcessManager struct and impl
│   └── port.rs         ← port allocation logic
└── config.rs           ← app configuration
```

Keep `lib.rs` as the entry point that declares modules. Business logic lives in the modules, not in `lib.rs` itself.

### Naming

`snake_case` for functions, methods, variables, and modules. `PascalCase` for types, structs, enums, and traits. `SCREAMING_SNAKE_CASE` for constants and statics.

Specific conventions:
- No `get_` prefix on getters — `port()` not `get_port()`
- Boolean methods use `is_`, `has_`, `can_`: `is_running()`, `has_started()`
- `new()` for the primary constructor
- Conversion methods: `as_` (cheap, borrowed → borrowed), `to_` (allocating), `into_` (consumes self)

### Idiomatic patterns

Prefer iterator chains over explicit loops when transforming data — they read at a higher level and the compiler optimises them equally well:

```rust
// Non-idiomatic
let mut available = Vec::new();
for p in 8934..9000 {
    if is_available(p) { available.push(p); }
}

// Idiomatic
let available: Vec<u16> = (8934..9000).filter(|&p| is_available(p)).collect();
```

Use `if let` when only one match arm matters:

```rust
if let Some(mut child) = self.child.take() {
    child.start_kill()?;
}
```

Use expression style rather than statement style:

```rust
// Non-idiomatic
let level;
if debug { level = "debug"; } else { level = "info"; }

// Idiomatic
let level = if debug { "debug" } else { "info" };
```

### Enforce with tooling

Run `rustfmt` and `clippy` on every commit. Both are CI gates. When clippy flags something, understand why — it is usually teaching a more idiomatic pattern, not just complaining.

---

## Refactor triggers

Refactor when:

- A method exceeds 20 lines
- A class has more than 7 public methods
- You feel the urge to add a comment explaining what code does
- Test setup requires more than 10 lines

Do not refactor when:

- Code works and is already clear
- The only reason is "it feels unorganised"
- You are adding abstraction for a hypothetical future case

---

## Shell Scripts

### Fail fast

Every script starts with:

```bash
set -euo pipefail
```

`-e` exits on error. `-u` exits on undefined variable. `-o pipefail` catches pipe failures.

### Clarity over cleverness

Shell scripts are infrastructure. Write them to be understood by someone unfamiliar with the codebase.

```bash
# Bad
[ -f "$RUBY_BIN" ] && echo "Ruby found" || { echo "Ruby missing"; exit 1; }

# Good
if [ ! -f "$RUBY_BIN" ]; then
  echo "Error: Ruby binary not found at $RUBY_BIN"
  exit 1
fi
echo "Ruby found at $RUBY_BIN"
```

### Phase structure

Bundle scripts are divided into numbered phases with a clear header and completion message:

```bash
# ============================================================
# Phase 3: Copy Ruby dylibs
# ============================================================
echo "→ Copying Ruby dylibs..."
# ...
echo "✓ Ruby dylibs copied"
```

### Variables

UPPERCASE for script-level variables. Quote all variable expansions.

```bash
RUBY_VERSION="4.0.0"
RUBY_SRC="/usr/local/opt/ruby/bin/ruby"

cp "$RUBY_SRC" "$RUBY_DEST"
```

---

## HTML / CSS / JavaScript (Launcher)

The launcher is a static splash screen. Keep it simple.

### No build step

No Vite, no webpack, no TypeScript. One `index.html` file, one `loading.css`. That's it.

### VanillaJS only

The launcher has one job: wait for Rails to be ready, then navigate. That does not require a framework.

```javascript
const { invoke } = window.__TAURI__.core;

async function waitForRails() {
  const port = await invoke("get_rails_port");
  window.location.href = `http://localhost:${port}`;
}

waitForRails();
```

### CSS

Plain CSS. Class names describe what the element is, not how it looks.

```css
/* Bad — layout utility classes in HTML */
<div class="flex items-center justify-center h-screen">

/* Good — semantic class in CSS */
.launcher        { display: flex; align-items: center; justify-content: center; min-height: 100vh; }
.launcher__logo  { width: 64px; height: 64px; }
.launcher__spinner { /* ... */ }
```

---

## Commits

Short imperative subject line. No emoji. No period. 50 characters or less.

```
Add ARM64 bundling script
Fix dylib path rewriting for libssl
Remove Vite dependency from launcher
```

Reference issues where relevant: `Closes #6`

Body (optional) explains *why*, not *what*:

```
Remove Vite dependency from launcher

The launcher is a static splash screen with ~10 lines of JS.
A full Vite build pipeline was unnecessary overhead. Plain HTML
and a co-located CSS file are sufficient and remove the npm
build step from the developer workflow.

Closes #3
```
