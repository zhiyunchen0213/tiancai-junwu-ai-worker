import React from "react";
import { interpolate, useCurrentFrame } from "remotion";

interface Props {
  text: string;
  durationInFrames: number;
  position?: "bottom_center" | "top_center";
}

export const SubtitleOverlay: React.FC<Props> = ({
  text,
  durationInFrames,
  position = "bottom_center",
}) => {
  const frame = useCurrentFrame();

  // Fade in/out
  const opacity = interpolate(
    frame,
    [0, 10, durationInFrames - 10, durationInFrames],
    [0, 1, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" }
  );

  const isTop = position === "top_center";

  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        [isTop ? "top" : "bottom"]: "8%",
        display: "flex",
        justifyContent: "center",
        opacity,
        zIndex: 10,
      }}
    >
      <div
        style={{
          backgroundColor: "rgba(0, 0, 0, 0.7)",
          color: "white",
          padding: "12px 24px",
          borderRadius: 8,
          fontSize: 32,
          fontFamily: "Arial, Helvetica, sans-serif",
          fontWeight: 500,
          maxWidth: "80%",
          textAlign: "center",
          lineHeight: 1.4,
          textShadow: "0 2px 4px rgba(0,0,0,0.5)",
        }}
      >
        {text}
      </div>
    </div>
  );
};
