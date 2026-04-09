import React from "react";
import {
  AbsoluteFill,
  Audio,
  Sequence,
  useVideoConfig,
  staticFile,
} from "remotion";
import type { LVInputProps, Segment } from "../lib/types";
import { KenBurnsImage } from "../components/KenBurnsImage";
import { SubtitleOverlay } from "../components/SubtitleOverlay";
import { OpeningVideo } from "../components/OpeningVideo";

const KB_DIRECTIONS = ["zoom-in", "zoom-out", "pan-right", "pan-left"] as const;

export const ElderlyStoryTemplate: React.FC<LVInputProps> = ({
  segments,
  audioFiles,
  imageFiles,
  openingVideoPath,
  config,
}) => {
  const { fps } = useVideoConfig();

  return (
    <AbsoluteFill style={{ backgroundColor: "#000" }}>
      {segments.map((seg, i) => {
        const durationInFrames = seg.endFrame - seg.startFrame;
        if (durationInFrames <= 0) return null;

        // Find matching audio
        const audio = audioFiles.find((a) => a.index === seg.index);
        // Find matching image
        const image = imageFiles.find((img) => img.index === seg.index);

        // Ken Burns direction cycles through options
        const kbDirection = KB_DIRECTIONS[i % KB_DIRECTIONS.length];

        return (
          <Sequence
            key={seg.index}
            from={seg.startFrame}
            durationInFrames={durationInFrames}
          >
            {/* Visual layer */}
            <AbsoluteFill>
              {seg.segmentType === "digital_human" && openingVideoPath ? (
                <OpeningVideo src={openingVideoPath} />
              ) : image ? (
                <KenBurnsImage
                  src={image.path}
                  durationInFrames={durationInFrames}
                  direction={config.kenBurns ? kbDirection : "zoom-in"}
                />
              ) : (
                /* Fallback: black screen with text */
                <AbsoluteFill
                  style={{
                    backgroundColor: "#1a1a2e",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    padding: 60,
                  }}
                >
                  <div
                    style={{
                      color: "#e0e0e0",
                      fontSize: 28,
                      textAlign: "center",
                      fontFamily: "Georgia, serif",
                      lineHeight: 1.6,
                      fontStyle: "italic",
                    }}
                  >
                    {seg.text}
                  </div>
                </AbsoluteFill>
              )}
            </AbsoluteFill>

            {/* Audio layer */}
            {audio && (
              <Audio src={audio.path} volume={1} />
            )}

            {/* Subtitle overlay */}
            {config.subtitleStyle !== "none" && (
              <SubtitleOverlay
                text={seg.text}
                durationInFrames={durationInFrames}
                position={config.subtitleStyle}
              />
            )}
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};
