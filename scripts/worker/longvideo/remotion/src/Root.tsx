import { Composition } from "remotion";
import { ElderlyStoryTemplate } from "./compositions/ElderlyStoryTemplate";
import type { LVInputProps } from "./lib/types";

const defaultProps: LVInputProps = {
  segments: [],
  audioFiles: [],
  imageFiles: [],
  width: 1920,
  height: 1080,
  fps: 30,
  durationInFrames: 300,
  config: {
    kenBurns: true,
    transition: "crossfade",
    transitionDuration: 0.5,
    subtitleStyle: "bottom_center",
    introDuration: 3,
    outroDuration: 5,
  },
};

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="ElderlyStoryTemplate"
        component={ElderlyStoryTemplate}
        durationInFrames={300}
        fps={30}
        width={1920}
        height={1080}
        defaultProps={defaultProps}
        calculateMetadata={({ props }) => ({
          durationInFrames: props.durationInFrames,
          fps: props.fps,
          width: props.width,
          height: props.height,
        })}
      />
      {/* 9:16 portrait version for Shorts */}
      <Composition
        id="ElderlyStoryTemplate-Portrait"
        component={ElderlyStoryTemplate}
        durationInFrames={300}
        fps={30}
        width={1080}
        height={1920}
        defaultProps={{ ...defaultProps, width: 1080, height: 1920 }}
        calculateMetadata={({ props }) => ({
          durationInFrames: props.durationInFrames,
          fps: props.fps,
          width: props.width,
          height: props.height,
        })}
      />
    </>
  );
};
