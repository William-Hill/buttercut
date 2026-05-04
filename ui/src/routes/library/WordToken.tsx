// ui/src/routes/library/WordToken.tsx
import { useRef } from "react";
import type { AudioWord } from "./types";

export interface WordTokenProps {
  word: AudioWord;
  segmentIndex: number;
  wordIndex: number;
  onSeek: (seconds: number) => void;
  onEditRequest: (anchor: HTMLElement, segmentIndex: number, wordIndex: number, currentToken: string) => void;
}

export default function WordToken({ word, segmentIndex, wordIndex, onSeek, onEditRequest }: WordTokenProps) {
  const ref = useRef<HTMLSpanElement | null>(null);

  return (
    <span ref={ref} className="row__word-wrap" data-segment={segmentIndex} data-word-index={wordIndex}>
      <button
        className="row__word"
        onClick={() => onSeek(word.start)}
        onKeyDown={(e) => {
          if (e.key === "e" && (e.metaKey || e.ctrlKey === false)) {
            e.preventDefault();
            if (ref.current) onEditRequest(ref.current, segmentIndex, wordIndex, word.word);
          }
        }}
      >
        {word.word}
      </button>
      <button
        className="row__pencil"
        title="Edit word"
        aria-label={`Edit word ${word.word}`}
        onClick={(e) => {
          e.stopPropagation();
          if (ref.current) onEditRequest(ref.current, segmentIndex, wordIndex, word.word);
        }}
      >
        ✎
      </button>
    </span>
  );
}
