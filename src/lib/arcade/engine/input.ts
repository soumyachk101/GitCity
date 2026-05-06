import type { Direction } from "../types";

export type MoveCallback = (dir: Direction) => void;

const KEY_MAP: Record<string, Direction> = {
  w: "up",
  a: "left",
  s: "down",
  d: "right",
  arrowup: "up",
  arrowleft: "left",
  arrowdown: "down",
  arrowright: "right",
};

const MOVE_INTERVAL_SEC = 0.15; // Matches LERP_DURATION in page.tsx — each lerp
                                // completes exactly when the next move fires, giving
                                // constant tile-velocity with no speed pulse.

// ─── State ────────────────────────────────────────────────────
const heldKeys = new Set<Direction>();
let moveCooldown = 0;
let moveCallback: MoveCallback | null = null;
let typingCheck: (() => boolean) | null = null;

function getActiveDir(): Direction | null {
  let last: Direction | null = null;
  for (const d of heldKeys) last = d;
  return last;
}

// ─── Called from game loop update(dt) ─────────────────────────
export function updateMovement(dt: number): void {
  if (!moveCallback) return;
  if (typingCheck?.()) return;

  const dir = getActiveDir();
  if (!dir) {
    return;
  }

  moveCooldown -= dt;
  if (moveCooldown <= 0) {
    moveCallback(dir);
    moveCooldown = MOVE_INTERVAL_SEC;
  }
}

// ─── Keyboard listeners ───────────────────────────────────────
export function attachInput(
  onMove: MoveCallback,
  isTyping: () => boolean,
): () => void {
  moveCallback = onMove;
  typingCheck = isTyping;

  const onKeyDown = (e: KeyboardEvent) => {
    if (isTyping()) return;

    const dir = KEY_MAP[e.key.toLowerCase()];
    if (!dir) return;

    e.preventDefault();

    // Re-add to end: last pressed = active direction
    heldKeys.delete(dir);
    heldKeys.add(dir);

    // Note: we intentionally do NOT reset moveCooldown on direction change.
    // With client-side prediction, stacking a new-direction input on top of a
    // still-pending old-direction input produces diagonal render artifacts.
    // Letting the current tile-step complete first keeps motion clean.
  };

  const onKeyUp = (e: KeyboardEvent) => {
    const dir = KEY_MAP[e.key.toLowerCase()];
    if (!dir) return;

    heldKeys.delete(dir);
  };

  const onBlur = () => {
    heldKeys.clear();
    moveCooldown = 0;
  };

  window.addEventListener("keydown", onKeyDown);
  window.addEventListener("keyup", onKeyUp);
  window.addEventListener("blur", onBlur);

  return () => {
    moveCallback = null;
    typingCheck = null;
    heldKeys.clear();
    moveCooldown = 0;
    window.removeEventListener("keydown", onKeyDown);
    window.removeEventListener("keyup", onKeyUp);
    window.removeEventListener("blur", onBlur);
  };
}
