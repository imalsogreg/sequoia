{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}

-- Strongly inspired by Helm.
-- See: http://helm-engine.org

module Game.Sequoia
    ( EngineConfig (..)
    , play
    , module Control.Applicative
    , module Game.Sequoia.Geometry
    , module Game.Sequoia.Scene
    , module Game.Sequoia.Signal
    , module Game.Sequoia.Time
    , module Game.Sequoia.Types
    , Engine ()
    , rgb
    , rgba
    ) where

import           Control.Applicative
import           Control.Monad (forM_)
import           Data.Bits ((.|.))
import           Data.SG.Shape
import qualified Data.Text as T
import           Foreign.C.String (withCAString)
import           Foreign.Marshal.Alloc (alloca)
import           Foreign.Ptr (nullPtr, castPtr)
import           Foreign.Storable (peek)
import           Game.Sequoia.Color
import           Game.Sequoia.Engine
import           Game.Sequoia.Geometry
import           Game.Sequoia.Scene
import           Game.Sequoia.Signal
import           Game.Sequoia.Time
import           Game.Sequoia.Types
import           Game.Sequoia.Utils
import           Game.Sequoia.Window
import qualified Graphics.Rendering.Cairo as Cairo
import qualified Graphics.Rendering.Pango as Pango
import qualified SDL.Raw as SDL
import           System.Endian (fromBE32)

data EngineConfig = EngineConfig
  { windowDimensions :: (Int, Int)
  -- windowIsFullscreen :: Bool,
  -- windowIsResizable :: Bool,
  , windowTitle :: String
  , windowColor :: Color
  }

startup :: EngineConfig -> IO Engine
startup (EngineConfig { .. }) = withCAString windowTitle $ \title -> do
    let (w, h) = mapT fromIntegral windowDimensions
        wflags = foldl (.|.) 0 $
            [ SDL.SDL_WINDOW_SHOWN
            -- , SDL.SDL_WINDOW_RESIZABLE  | windowIsResizable
            -- , SDL.SDL_WINDOW_FULLSCREEN | windowIsFullscreen
            ]
        rflags = SDL.SDL_RENDERER_PRESENTVSYNC .|.
                 SDL.SDL_RENDERER_ACCELERATED

    window   <- SDL.createWindow title 0 0 w h wflags
    renderer <- SDL.createRenderer window (-1) rflags
    return Engine { window    = window
                  , renderer  = renderer
                  , continue  = True
                  , backColor = windowColor
                  }

play :: EngineConfig
     -> (Engine -> N i)
     -> (i -> N (B (Prop' a)))
     -> IO ()
play cfg initial sceneN = do
    runNowMaster $ do
        engine   <- sync $ startup cfg
        sceneSig <- initial engine >>= sceneN
        dimSig   <- getDimensions engine
        quit     <- poll $ wantsQuit engine sceneSig dimSig
        sample $ whenE quit
    SDL.quit

wantsQuit :: Engine -> B (Prop' a) -> B (Int, Int) -> N Bool
wantsQuit engine sceneSig dimSig = do
    scene <- sample sceneSig
    dims  <- sample dimSig
    sync $ do
        render engine scene dims
        SDL.quitRequested

render :: Engine -> Prop' a -> (Int, Int) -> IO ()
render (Engine { .. }) ps size@(w, h) =
    alloca $ \pixelsptr ->
    alloca $ \pitchptr  -> do
        format <- SDL.masksToPixelFormatEnum 32 (fromBE32 0x0000ff00)
                                                (fromBE32 0x00ff0000)
                                                (fromBE32 0xff000000)
                                                (fromBE32 0x000000ff)
        texture <-
            SDL.createTexture
                renderer
                format
                SDL.SDL_TEXTUREACCESS_STREAMING
                (fromIntegral w)
                (fromIntegral h)
        SDL.lockTexture texture nullPtr pixelsptr pitchptr
        pixels <- peek pixelsptr
        pitch  <- fromIntegral <$> peek pitchptr
        Cairo.withImageSurfaceForData
            (castPtr pixels)
            Cairo.FormatARGB32
            (fromIntegral w)
            (fromIntegral h)
            pitch
            $ \surface ->
                Cairo.renderWith surface $ do
                  unpackColFor backColor Cairo.setSourceRGBA
                  uncurry (Cairo.rectangle 0 0) $ mapT fromIntegral size
                  Cairo.fill
                  render' ps size
        SDL.unlockTexture texture
        SDL.renderClear renderer
        SDL.renderCopy renderer texture nullPtr nullPtr
        SDL.destroyTexture texture
        SDL.renderPresent renderer

render' :: Prop' a -> (Int, Int) -> Cairo.Render ()
render' ps size = do
    Cairo.save
    uncurry Cairo.translate $ mapT ((/ 2) . fromIntegral) size
    mapM_ renderProp ps
    Cairo.restore

renderProp :: Piece a -> Cairo.Render ()
renderProp (ShapePiece _ f)  = renderForm f
renderProp (StanzaPiece _ s) = renderStanza s

renderStanza :: Stanza -> Cairo.Render ()
renderStanza (Stanza { .. }) = do
    layout <- Pango.createLayout stanzaUTF8

    Cairo.liftIO
        $ Pango.layoutSetAttributes layout
        [ Pango.AttrFamily { paStart = i, paEnd = j, paFamily = stanzaTypeface }
        , Pango.AttrWeight { paStart = i, paEnd = j, paWeight = mapFontWeight stanzaWeight }
        , Pango.AttrStyle  { paStart = i, paEnd = j, paStyle = mapFontStyle stanzaStyle }
        , Pango.AttrSize   { paStart = i, paEnd = j, paSize = stanzaHeight }
        ]

    Pango.PangoRectangle _ _ w h <- fmap snd . Cairo.liftIO
                                             $ Pango.layoutGetExtents layout

    unpackFor stanzaCentre Cairo.moveTo
    flip Cairo.relMoveTo (-h / 2) $ case stanzaAlignment of
      LeftAligned  -> 0
      Centered     -> -w / 2
      RightAligned -> -w
    unpackColFor stanzaColor Cairo.setSourceRGBA
    Pango.showLayout layout

  where
    i = 0
    j = T.length stanzaUTF8
    mapFontWeight weight =
        case weight of
          LightWeight  -> Pango.WeightLight
          NormalWeight -> Pango.WeightNormal
          BoldWeight   -> Pango.WeightBold
    mapFontStyle style =
        case style of
          NormalStyle  -> Pango.StyleNormal
          ObliqueStyle -> Pango.StyleOblique
          ItalicStyle  -> Pango.StyleItalic

renderForm :: Form -> Cairo.Render ()
renderForm (Form (Style mfs mls) s) = do
    Cairo.newPath
    case s of
      Rectangle { .. } -> do
          let (w, h) = mapT (*2) rectSize
              (x, y) = unpackPos shapeCentre
          Cairo.rectangle (x - w/2) (y - h/2) w h

      Polygon { .. } -> do
          forM_ polyPoints $ \r -> do
              let pos = plusDir shapeCentre r
              unpackFor pos Cairo.lineTo
          Cairo.closePath

      Circle { .. } -> do
          unpackFor shapeCentre Cairo.arc circSize 0 (pi * 2)
    mapM_ setFillStyle mfs
    mapM_ setLineStyle mls

setLineStyle :: LineStyle -> Cairo.Render ()
setLineStyle (LineStyle { .. }) = do
    unpackColFor lineColor Cairo.setSourceRGBA
    setLineCap
    setLineJoin
    Cairo.setLineWidth lineWidth
    Cairo.setDash lineDashing lineDashOffset
    Cairo.strokePreserve
  where
    setLineCap = Cairo.setLineCap $
        case lineCap of
          FlatCap   -> Cairo.LineCapButt
          RoundCap  -> Cairo.LineCapRound
          PaddedCap -> Cairo.LineCapSquare
    setLineJoin =
        case lineJoin of
          SmoothJoin    -> Cairo.setLineJoin Cairo.LineJoinRound
          SharpJoin lim -> Cairo.setLineJoin Cairo.LineJoinMiter
                        >> Cairo.setMiterLimit lim
          ClippedJoin   -> Cairo.setLineJoin Cairo.LineJoinBevel


setFillStyle :: FillStyle -> Cairo.Render ()
setFillStyle (Solid col) = do
    unpackColFor col Cairo.setSourceRGBA
    Cairo.fillPreserve

unpackFor :: Pos -> (Double -> Double -> a) -> a
unpackFor p f = uncurry f $ unpackPos p

unpackColFor :: Color
             -> (Double -> Double ->  Double -> Double -> a)
             -> a
unpackColFor (Color r g b a) f = f r g b a

