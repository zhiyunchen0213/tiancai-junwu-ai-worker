import React from "react";
import { Img, interpolate, useCurrentFrame } from "remotion";

interface Props {
  src: string;
  durationInFrames: number;
  /** Pan direction: determines which corner to start from */
  direction?: "zoom-in" | "zoom-out" | "pan-right" | "pan-left";
  style?: React.CSSProperties;
}

export const KenBurnsImage: React.FC<Props> = ({
  src,
  durationInFrames,
  direction = "zoom-in",
  style,
}) => {
  const frame = useCurrentFrame();

  const progress = interpolate(frame, [0, durationInFrames], [0, 1], {
    extrapolateRight: "clamp",
  });

  let scale: number;
  let translateX: number;
  let translateY: number;

  switch (direction) {
    case "zoom-in":
      scale = interpolate(progress, [0, 1], [1, 1.15]);
      translateX = interpolate(progress, [0, 1], [0, -2]);
      translateY = interpolate(progress, [0, 1], [0, -2]);
      break;
    case "zoom-out":
      scale = interpolate(progress, [0, 1], [1.15, 1]);
      translateX = interpolate(progress, [0, 1], [-2, 0]);
      translateY = interpolate(progress, [0, 1], [-2, 0]);
      break;
    case "pan-right":
      scale = 1.1;
      translateX = interpolate(progress, [0, 1], [-3, 3]);
      translateY = 0;
      break;
    case "pan-left":
      scale = 1.1;
      translateX = interpolate(progress, [0, 1], [3, -3]);
      translateY = 0;
      break;
  }

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        overflow: "hidden",
        ...style,
      }}
    >
      <Img
        src={src}
        style={{
          width: "100%",
          height: "100%",
          objectFit: "cover",
          transform: `scale(${scale}) translate(${translateX}%, ${translateY}%)`,
        }}
      />
    </div>
  );
};
