import React from "react";
import { OffthreadVideo, useVideoConfig } from "remotion";

interface Props {
  src: string;
}

export const OpeningVideo: React.FC<Props> = ({ src }) => {
  const { width, height } = useVideoConfig();

  return (
    <OffthreadVideo
      src={src}
      style={{
        width,
        height,
        objectFit: "cover",
      }}
    />
  );
};
