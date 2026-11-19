#!/bin/zsh
# Builds a fictional demo workspace for the Proj demo videos (no real projects appear in them).
# usage: seed.sh <work dir>   — writes <work dir>/data/Projects (and two generated photos)
set -e
REPO=${0:A:h:h:h}
D=${1:?usage: seed.sh <work dir>}; mkdir -p $D
export PROJ_ROOT=$D/data/Projects
P=$REPO/.venv/bin/proj
rm -rf $D/data && mkdir -p $PROJ_ROOT/"1 - Template"/{Documents,Receipts} $PROJ_ROOT/"2 - Closed" $PROJ_ROOT/"3 - Receipts"
cat > $PROJ_ROOT/"1 - Template"/README.md <<'T'
---
format: 1
title: Project
area: Area
status: active
created: 2026-11-02
closed:
tags: []
goals: []
links: []
receipts: []
---

## Description

## Tasks

## Project Files

## Notes
T
printf '# Idea Backlog\n\nThings to maybe do someday.\n\n' > $PROJ_ROOT/"0 - Idea Backlog.md"
for a in Home Garden Health Learning "Side Projects"; do mkdir -p "$PROJ_ROOT/$a"; done

new() { $P new "$1" -a "$2" -s "${3:-active}" >/dev/null; }
desc() { python3 - "$PROJ_ROOT" "$1" "$2" <<'PY'
import sys,glob,re
root,name,text=sys.argv[1:]
f=glob.glob(f"{root}/*/{name}/README.md")[0]
s=open(f).read().replace("## Description\n","## Description\n"+text+"\n",1)
open(f,"w").write(s)
PY
}
goal() { $P goal add "$1" "$2" >/dev/null; }
task() { $P task add "$1" "$2" >/dev/null; }

# --- Home
new "Kitchen Remodel" Home active
desc "Kitchen Remodel" "Replace the cabinets and counters, add under-cabinet lighting, and refinish the floor."
goal "Kitchen Remodel" "Pick a contractor"; goal "Kitchen Remodel" "Finalize the layout"; goal "Kitchen Remodel" "Finish before the holidays"
task "Kitchen Remodel" "Get three contractor quotes"
task "Kitchen Remodel" "Choose countertop material"
task "Kitchen Remodel" "Order cabinet hardware"
task "Kitchen Remodel" "Schedule electrician for lighting"
task "Kitchen Remodel" "Measure the pantry wall"
$P goal done "Kitchen Remodel" 1 >/dev/null; $P goal done "Kitchen Remodel" 2 >/dev/null
$P task done "Kitchen Remodel" "Measure the pantry wall" >/dev/null
$P task note "Kitchen Remodel" "Choose countertop material" "Quartz vs. butcher block — bring samples home" >/dev/null
$P link add "Kitchen Remodel" "https://www.houzz.com/photos/kitchen" -t "Inspiration board" >/dev/null
$P file add "Kitchen Remodel" "https://example.com/kitchen-layout" -n "Layout sketch" >/dev/null
$P note "Kitchen Remodel" "Second quote came in 10% under the first." >/dev/null

new "Roof Repair" Home blocked
desc "Roof Repair" "Fix the flashing around the chimney before winter."
task "Roof Repair" "Wait for roofer's availability"
task "Roof Repair" "Clear the gutters"
$P note "Roof Repair" "Roofer is booked until next month." >/dev/null

new "Garage Organization" Home backlog
task "Garage Organization" "Install wall shelving"
task "Garage Organization" "Donate old bikes"

# --- Garden
new "Vegetable Beds" Garden active
desc "Vegetable Beds" "Build two raised beds and plan the spring planting."
goal "Vegetable Beds" "Build the raised beds"; goal "Vegetable Beds" "Plant by April"
task "Vegetable Beds" "Buy cedar boards"
task "Vegetable Beds" "Order soil and compost"
task "Vegetable Beds" "Sketch the planting plan"
task "Vegetable Beds" "Test soil pH"
$P goal done "Vegetable Beds" 1 >/dev/null
$P task done "Vegetable Beds" "Buy cedar boards" >/dev/null

new "Fruit Trees" Garden on-hold
task "Fruit Trees" "Research dwarf apple varieties"

new "Irrigation" Garden completed-on-hold
task "Irrigation" "Install drip lines"
$P task done "Irrigation" 1 >/dev/null

# --- Health
new "Marathon Training" Health active
desc "Marathon Training" "16-week plan for the spring marathon."
goal "Marathon Training" "Run a half marathon"; goal "Marathon Training" "Long run of 20 miles"; goal "Marathon Training" "Finish under 4 hours"
$P goal done "Marathon Training" 1 >/dev/null
task "Marathon Training" "Buy new running shoes"
task "Marathon Training" "Book a physio check-up"
task "Marathon Training" "Plan race-day nutrition"
$P link add "Marathon Training" "https://www.strava.com" -t "Strava" >/dev/null

new "Meal Planning" Health idea

# --- Learning
new "Learn Spanish" Learning active
desc "Learn Spanish" "Conversational Spanish before the trip to Madrid."
goal "Learn Spanish" "Finish A2 course"; goal "Learn Spanish" "Hold a 10-minute conversation"
task "Learn Spanish" "Daily vocabulary practice"
task "Learn Spanish" "Find a conversation partner"
task "Learn Spanish" "Watch a film without subtitles"

new "Woodworking Class" Learning backlog
task "Woodworking Class" "Sign up for the spring session"

# --- Side Projects
new "Family Photo Book" "Side Projects" active
desc "Family Photo Book" "A printed photo book of this year's family trips."
goal "Family Photo Book" "Pick 100 photos"; goal "Family Photo Book" "Order the book"
task "Family Photo Book" "Gather photos from everyone"
task "Family Photo Book" "Choose a layout template"
task "Family Photo Book" "Write captions"

new "Home Lab Server" "Side Projects" completed-on-hold
task "Home Lab Server" "Set up backups"
$P task done "Home Lab Server" 1 >/dev/null

new "Old Website" "Side Projects" active
$P close "Old Website" >/dev/null

# Receipts (spending) — written straight into front matter
python3 - "$PROJ_ROOT" <<'PY'
import sys,glob
root=sys.argv[1]
def add(name, rows):
    f=glob.glob(f"{root}/*/{name}/README.md")[0]
    s=open(f).read()
    block="receipts:\n"+"".join(f"  - path: 2026/{d} {v}.pdf\n    amount: {a}\n    vendor: {v}\n    date: {d}\n" for d,v,a in rows)
    s=s.replace("receipts: []\n",block,1); open(f,"w").write(s)
add("Kitchen Remodel",[("2026-11-04","Home Depot",412.50),("2026-11-10","Lumber Yard",1285.00)])
add("Vegetable Beds",[("2026-11-08","Garden Center",186.40)])
add("Marathon Training",[("2026-11-12","Running Store",149.99)])
PY

# Photos (generated gradients)
ffmpeg -loglevel error -y -f lavfi -i "gradients=s=1600x1200:c0=0xd9b38c:c1=0x8c6239:seed=3" -frames:v 1 $D/photo1.jpg
ffmpeg -loglevel error -y -f lavfi -i "gradients=s=1600x1200:c0=0x9bc98a:c1=0x3f6e35:seed=5" -frames:v 1 $D/photo2.jpg
$P photo add "Kitchen Remodel" $D/photo1.jpg -n "Current cabinets, before" >/dev/null
$P photo add "Vegetable Beds" $D/photo2.jpg -n "Where the beds will go" >/dev/null

# Today
$P task today "Kitchen Remodel" "Get three contractor quotes" >/dev/null
$P task today "Marathon Training" "Buy new running shoes" >/dev/null
$P task today "Learn Spanish" "Daily vocabulary practice" >/dev/null
$P today add "Call the vet about Max's checkup" >/dev/null
$P today add "Pick up dry cleaning" >/dev/null

# Archive
task "Garage Organization" "Sell the old lawn mower"
$P task done "Garage Organization" "Sell the old lawn mower" >/dev/null
$P task archive "Garage Organization" "Sell the old lawn mower" >/dev/null
task "Learn Spanish" "Buy a phrasebook"
$P task done "Learn Spanish" "Buy a phrasebook" >/dev/null
$P task archive "Learn Spanish" "Buy a phrasebook" >/dev/null

# Ideas
$P idea add "Build a backyard fire pit" >/dev/null
$P idea add "Start a podcast about local history" >/dev/null
$P idea add "Digitize old vinyl records" >/dev/null

$P order area Home 1 >/dev/null; $P order area Garden 2 >/dev/null; $P order area Health 3 >/dev/null; $P order area Learning 4 >/dev/null
$P lint || true
$P ls
