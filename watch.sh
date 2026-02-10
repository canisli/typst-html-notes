#!/bin/bash

# Typst Notes Watcher
# Uses typst watch for compilation, wraps with reader template, serves with live reload
# Usage: bash watch.sh [note.typ] [port]
# Access at: http://localhost:PORT/notename/
#
# Multiple watchers can run simultaneously - they share a single HTTP server.
# The first watcher starts the server; subsequent ones detect it and join.
# Stopping the server owner stops the server; other watchers keep running.
#
# In browser: Ctrl+R = incremental update (preserves scroll), Cmd+R = full reload

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="${1:-notes.typ}"
PORT="${2:-8741}"  # Uncommon port, shared across all watchers

# Extract note name (without .typ extension)
NOTE_NAME=$(basename "$INPUT" .typ)

# Output goes to dist/{notename}/
OUTPUT_DIR="$SCRIPT_DIR/dist/$NOTE_NAME"
DIST_ROOT="$SCRIPT_DIR/dist"

echo "╔════════════════════════════════════════╗"
echo "║     Typst Notes - Watch Mode           ║"
echo "╚════════════════════════════════════════╝"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# --- Shared server detection ------------------------------------------------
# Multiple watchers share a single HTTP server. First one starts it, others join.

I_AM_SERVER=false

# Check if our server is already responding
check_server() {
    curl -s --connect-timeout 1 --max-time 2 "http://localhost:$PORT/" > /dev/null 2>&1
}

# Function to rebuild the wrapper
rebuild_wrapper() {
    local content_file="$OUTPUT_DIR/content.html"
    local template_file="$SCRIPT_DIR/reader-template.html"
    local output_file="$OUTPUT_DIR/index.html"
    local source_file="$SCRIPT_DIR/$INPUT"
    
    # Extract title from HTML
    local title=$(grep -o '<title>[^<]*</title>' "$content_file" 2>/dev/null | sed 's/<[^>]*>//g')
    [ -z "$title" ] && title="$NOTE_NAME"
    
    # Extract course and term metadata from source .typ file
    # Format: // @course: 6.1220 Algorithms
    #         // @term: Fall 2025
    local course=$(grep -m1 '^// *@course:' "$source_file" 2>/dev/null | sed 's/^\/\/ *@course: *//')
    local term=$(grep -m1 '^// *@term:' "$source_file" 2>/dev/null | sed 's/^\/\/ *@term: *//')
    
    # Fall back to title if no course specified
    [ -z "$course" ] && course="$title"
    
    # Split template at {{CONTENT}} and concatenate with content in middle
    {
        sed -n '1,/{{CONTENT}}/p' "$template_file" | sed 's/{{CONTENT}}.*//' \
            | sed "s/{{TITLE}}/$title/g" \
            | sed "s/{{COURSE}}/$course/g" \
            | sed "s/{{TERM}}/$term/g"
        cat "$content_file"
        sed -n '/{{CONTENT}}/,$p' "$template_file" | sed '1s/.*{{CONTENT}}//' \
            | sed "s/{{TITLE}}/$title/g" \
            | sed "s/{{COURSE}}/$course/g" \
            | sed "s/{{TERM}}/$term/g"
    } > "$output_file"
    
    echo "✓ $course"
}

export SCRIPT_DIR
export NOTE_NAME

# Cleanup on exit - only kill server if we started it
cleanup() {
    echo ""
    echo "→ Shutting down $NOTE_NAME watcher..."
    [ -n "$TYPST_PID" ] && kill $TYPST_PID 2>/dev/null
    [ -n "$WATCH_PID" ] && kill $WATCH_PID 2>/dev/null
    if [ "$I_AM_SERVER" = true ] && [ -n "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null
        echo "→ Server stopped (was owner)"
    fi
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Initial compile
echo "→ Compiling $INPUT..."
typst compile "$SCRIPT_DIR/$INPUT" "$OUTPUT_DIR/content.html" --format html --features html --input html=true 2>&1 | grep -v "^warning:" | head -5
rebuild_wrapper
echo ""

# Create an index page listing all notes
create_index() {
    python3 << 'PYEOF'
import os

script_dir = os.environ.get('SCRIPT_DIR', '.')
dist_dir = os.path.join(script_dir, 'dist')

# Find all note directories
notes = []
for item in os.listdir(dist_dir):
    item_path = os.path.join(dist_dir, item)
    if os.path.isdir(item_path) and os.path.exists(os.path.join(item_path, 'index.html')):
        notes.append(item)

notes.sort()

html = '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Typst Notes</title>
  <link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@400;500;600&family=DM+Sans:wght@400;500&display=swap" rel="stylesheet">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'DM Sans', system-ui, sans-serif;
      background: #2F343F;
      color: #adbac7;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 40px 20px;
    }
    .container {
      max-width: 600px;
      width: 100%;
    }
    h1 {
      font-family: 'Cormorant Garamond', Georgia, serif;
      font-size: 2.5rem;
      font-weight: 500;
      color: #cdd9e5;
      margin-bottom: 0.5rem;
    }
    .subtitle {
      color: #768390;
      margin-bottom: 2rem;
      font-size: 0.9rem;
    }
    .notes-list {
      list-style: none;
    }
    .notes-list li {
      margin-bottom: 0.5rem;
    }
    .notes-list a {
      display: block;
      padding: 16px 20px;
      background: #2d333b;
      border-radius: 8px;
      color: #adbac7;
      text-decoration: none;
      transition: all 0.15s ease;
      border: 1px solid transparent;
    }
    .notes-list a:hover {
      background: #373e47;
      color: #cdd9e5;
      border-color: rgba(224, 120, 80, 0.3);
    }
    .note-name {
      font-weight: 500;
      font-size: 1.1rem;
    }
    .empty {
      color: #636e7b;
      font-style: italic;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>Typst Notes</h1>
    <p class="subtitle">Select a note to read</p>
    <ul class="notes-list">
'''

if notes:
    for note in notes:
        html += f'      <li><a href="/{note}/"><span class="note-name">{note}</span></a></li>\n'
else:
    html += '      <li class="empty">No notes compiled yet</li>\n'

html += '''    </ul>
  </div>
</body>
</html>'''

with open(os.path.join(dist_dir, 'index.html'), 'w') as f:
    f.write(html)
PYEOF
}

create_index

# Start HTTP server only if not already running
if check_server; then
    echo "→ Joining existing server at http://localhost:$PORT/"
    echo "  View this note: http://localhost:$PORT/$NOTE_NAME/"
else
    echo "→ Starting server at http://localhost:$PORT/"
    echo "  View this note: http://localhost:$PORT/$NOTE_NAME/"
    I_AM_SERVER=true
    
    if command -v node &>/dev/null; then
        node -e "
const http = require('http');
const fs = require('fs');
const path = require('path');
const root = '$DIST_ROOT';
const types = {'.html':'text/html','.css':'text/css','.js':'text/javascript','.svg':'image/svg+xml','.png':'image/png','.jpg':'image/jpeg'};

const server = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  
  // Content-only endpoint for Ctrl+R incremental updates
  if (url.endsWith('/__content')) {
    const notePath = url.replace('/__content', '');
    const contentFile = path.join(root, notePath, 'content.html');
    if (fs.existsSync(contentFile)) {
      res.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-cache'});
      fs.createReadStream(contentFile).pipe(res);
    } else {
      res.writeHead(404); res.end('Not found');
    }
    return;
  }
  
  // Normal file serving
  let p = path.join(root, url);
  if (fs.existsSync(p) && fs.statSync(p).isDirectory()) p = path.join(p, 'index.html');
  if (!fs.existsSync(p)) { res.writeHead(404); res.end('Not found'); return; }
  res.writeHead(200, {'Content-Type': types[path.extname(p)] || 'text/plain', 'Cache-Control': 'no-cache'});
  fs.createReadStream(p).pipe(res);
});

server.on('error', (err) => {
  console.error('HTTP server error:', err && err.message ? err.message : err);
  process.exit(1);
});

server.listen($PORT);
" &
        SERVER_PID=$!
    else
        cd "$DIST_ROOT" && python3 -m http.server "$PORT" >/dev/null 2>&1 &
        SERVER_PID=$!
        cd "$SCRIPT_DIR"
    fi
    
    # Wait a moment for server to start
    sleep 0.3
fi

# Start typst watch
echo "→ Watching: $INPUT"
echo ""
echo "════════════════════════════════════════"
echo "  http://localhost:$PORT/$NOTE_NAME/"
echo "  Ctrl+R = update content"
echo "  Cmd+R  = full reload"
if [ "$I_AM_SERVER" = true ]; then
    echo "  (server owner - stopping kills server)"
else
    echo "  (joined existing server)"
fi
echo "════════════════════════════════════════"
echo ""

# Run typst watch for compilation only.
# Typst 0.14+ starts a built-in HTTP server for HTML export by default (ports 3000-3005),
# which can fail with "could not find free port for HTTP server" if those ports are busy.
# We serve `dist/` ourselves, so disable Typst's built-in server and live reload.
# typst watch "$SCRIPT_DIR/$INPUT" "$OUTPUT_DIR/content.html" --format html --features html --input html=true --no-serve --no-reload 2>&1 | grep -E "(compiling|compiled|error)" &
typst watch "$SCRIPT_DIR/$INPUT" "$OUTPUT_DIR/content.html" --format html --features html --input html=true --no-serve --no-reload & #2>&1 | grep -E "(compiling|compiled|error)" &
TYPST_PID=$!

# Watch for content.html changes and rebuild wrapper
(
    LAST_MOD=""
    while true; do
        if [ -f "$OUTPUT_DIR/content.html" ]; then
            CURRENT_MOD=$(stat -f %m "$OUTPUT_DIR/content.html" 2>/dev/null || stat -c %Y "$OUTPUT_DIR/content.html" 2>/dev/null)
            if [ "$CURRENT_MOD" != "$LAST_MOD" ] && [ -n "$LAST_MOD" ]; then
                rebuild_wrapper
            fi
            LAST_MOD=$CURRENT_MOD
        fi
        sleep 0.1
    done
) &
WATCH_PID=$!

# Wait for typst watch
wait $TYPST_PID
