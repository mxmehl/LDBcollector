{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Ldbcollector.Server
  ( serve,
    writeSingleHtml,
  )
where

import Control.Monad.State qualified as MTL
import Data.ByteString qualified
import Data.ByteString.Lazy qualified as BL
import Data.Cache qualified as C
import Data.Colour qualified as Colour
import Data.Colour.SRGB qualified as Colour
import Data.FileEmbed (embedFile)
import Data.Graph.Inductive.Graph qualified as G
import Data.GraphViz.Attributes.Complete qualified as GV
import Data.Hashable (Hashable, hash)
import Data.Map qualified as Map
import Data.Text.Lazy qualified as T
import Data.Text.Lazy.IO qualified as I
import Data.Vector qualified as V
import Ldbcollector.Model
import Ldbcollector.Sink.GraphViz
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment qualified as Env
import System.IO.Temp qualified as Temp
import Text.Blaze.Html.Renderer.Text qualified as BT
import Text.Blaze.Html5 qualified as H
import Text.Blaze.Html5.Attributes qualified as A
import Web.Scotty as S

class ParamMapC a where
  getLicRaw :: a -> T.Text
  getLic :: a -> LicenseName
  getIsExcludeStmts :: a -> Bool
  getEnabledSources :: a -> [SourceRef]
  isSourceEnabled :: a -> SourceRef -> Bool

newtype ParamMap = ParamMap
  { unParamMap :: Map.Map T.Text T.Text
  }
  deriving (Eq, Hashable)

excludeStmts :: T.Text
excludeStmts = "excludeStmts"

instance ParamMapC ParamMap where
  getLicRaw = Map.findWithDefault "BSD-3-Clause" "license" . unParamMap
  getLic = fromText . T.toStrict . getLicRaw
  getIsExcludeStmts = ("on" ==) . Map.findWithDefault "off" excludeStmts . unParamMap
  getEnabledSources = map (Source . T.unpack . fst) . filter (\(_, value) -> value == "on") . Map.assocs . unParamMap
  isSourceEnabled pm s =
    let enabledSources = getEnabledSources pm
     in null enabledSources || s `elem` enabledSources

instance Show ParamMap where
  show pm =
    let assocs = (Map.assocs . unParamMap) pm
        licRaw = getLicRaw pm
        lic = getLic pm
        enabledSources = getEnabledSources pm
     in unlines
          [ "params=" ++ show assocs,
            "licRaw=" ++ show licRaw,
            "lic=" ++ show lic,
            "enabledSources=" ++ show enabledSources
          ]

evaluateParams :: [S.Param] -> IO ParamMap
evaluateParams params = do
  let pm = (ParamMap . Map.fromList) params
  debugLogIO (show pm)
  return pm

stylesheet :: Data.ByteString.ByteString
stylesheet = $(embedFile "src/assets/styles.css")

scriptJs :: Data.ByteString.ByteString
scriptJs = $(embedFile "src/assets/script.js")

lnToA :: Maybe String -> LicenseName -> H.Markup
lnToA queryparams ln = H.a H.! A.href ((H.toValue . (++ fromMaybe "" queryparams) . ("/?license=" ++) . show) ln) $ H.toMarkup ln

listPageAction :: [[LicenseName]] -> ActionM ()
listPageAction clusters = do
  let page = H.html $ do
        htmlHead "ldbcollector"
        H.body $ do
          H.ol $
            mapM_
              ( \cluster ->
                  H.li
                    ( H.ul H.! A.class_ "capsulUl clearfix" $
                        mapM_ (H.li . lnToA Nothing) cluster
                    )
              )
              clusters
  html (BT.renderHtml page)

printFactsForSource :: SourceRef -> LicenseGraph -> IO H.Html
printFactsForSource source licenseGraph = do
  ((facts, sourceInstance), _) <-
    runLicenseGraphM' licenseGraph $
      (,)
        <$> MTL.gets (filter (\(s, _) -> s == source) . Map.keys . _facts)
        <*> MTL.gets (Map.lookup source . _sources)
  return . H.html $ do
    htmlHead "ldbcollector"
    H.body $ do
      H.h1 $ H.toMarkup source
      case sourceInstance of
        Just sourceInstance' -> do
          H.toMarkup (getOriginalData sourceInstance')
        Nothing -> pure ()
      mapM_
        ( \(source, fact) -> do
            H.h2 $ do
              licenseFactUrl fact $ H.toMarkup (getFactId fact)
              " for "
              lnToA (Just $ "&" ++ show source ++ "=on") (getMainLicenseName fact)
            H.toMarkup (getLicenseNameCluster fact)
        )
        facts

printFacts :: FactId -> LicenseGraph -> IO H.Html
printFacts factId licenseGraph = do
  (facts, _) <-
    runLicenseGraphM' licenseGraph $
      MTL.gets (filter (\(_, f) -> getFactId f == factId) . Map.keys . _facts)
  return . H.html $ do
    htmlHead ("ldbcollector: fact:" <> (T.pack . show) factId)
    H.body $ do
      mapM_
        ( \(source, fact) -> do
            H.h1 $ do
              H.a H.! A.href (H.toValue $ "/source" </> show source) $ H.toMarkup (show source)
            H.h2 $ do
              H.toMarkup (getFactId fact)
              " for "
              lnToA (Just $ "&" ++ show source ++ "=on") (getMainLicenseName fact)
            toMarkup fact
            H.h3 "JSON"
            H.pre (H.toMarkup (bsToText (BL.toStrict (encodePretty fact))))
        )
        facts

extractSubgraph :: Bool -> ([G.Node], [G.Node], [G.Node]) -> LicenseGraphM (LicenseGraphType, LicenseNameGraphType, (Digraph, SourceRef -> GV.Color), LicenseNameCluster)
extractSubgraph isExcludeStmts (needleNames, sameNames, otherNames) =
    MTL.gets ((,,,) . _gr)
      <*> getLicenseNameGraph
      <*> ( do
              when isExcludeStmts $
                MTL.modify
                  ( \lg@LicenseGraph {_gr = gr} ->
                      lg
                        { _gr =
                            G.labfilter
                              ( \case
                                  LGName _ -> True
                                  LGFact _ -> True
                                  _ -> False
                              )
                              gr
                        }
                  )
              getDigraph needleNames sameNames otherNames
          )
      <*> getLicenseNameClusterM (needleNames, sameNames, otherNames)

computeSubgraph :: LicenseGraph -> ParamMap -> IO (LicenseGraphType, LicenseNameGraphType, (Digraph, SourceRef -> GV.Color), LicenseNameCluster)
computeSubgraph licenseGraph paramMap = do
  let licLN = LGName (getLic paramMap)
  let isExcludeStmts = getIsExcludeStmts paramMap
  fmap fst . runLicenseGraphM' licenseGraph $ do
    focus (getEnabledSources paramMap) (V.singleton licLN) $
      \(needleNames, sameNames, otherNames, _statements) -> extractSubgraph isExcludeStmts (needleNames, sameNames, otherNames)

htmlHead' :: Bool -> T.Text -> H.Markup
htmlHead' embedStyles title = do
  H.head $ do
    H.title (H.toMarkup title)
    H.link H.! A.rel "stylesheet" H.! A.href "https://unpkg.com/normalize.css@8.0.1/normalize.css"
    H.link H.! A.rel "stylesheet" H.! A.href "https://cdn.jsdelivr.net/npm/bootstrap@3.4.1/dist/css/bootstrap.min.css"
    H.link H.! A.rel "stylesheet" H.! A.href "https://cdn.jsdelivr.net/npm/bootstrap@3.4.1/dist/css/bootstrap-theme.min.css"
    if embedStyles
        then H.style $ H.toMarkup (bsToText stylesheet)
        else H.link H.! A.rel "stylesheet" H.! A.href "/styles.css"
    -- H.script H.! A.src "https://cdn.jsdelivr.net/npm/bootstrap@3.4.1/dist/js/bootstrap.min.js" $ pure ()
    H.script H.! A.src "https://d3js.org/d3.v5.min.js" $ pure ()
    H.script H.! A.src "https://unpkg.com/@hpcc-js/wasm@0.3.11/dist/index.min.js" $ pure ()
    H.script H.! A.src "https://unpkg.com/d3-graphviz@3.0.5/build/d3-graphviz.js" $ pure ()

htmlHead :: T.Text -> H.Markup
htmlHead = htmlHead' False

htmlHeader :: LicenseGraph -> (SourceRef -> GV.Color) -> ParamMap -> H.Markup
htmlHeader licenseGraph typeColoringLookup paramMap = do
  let allLicenseNames = getLicenseGraphLicenseNames licenseGraph
  let allSources = (nub . map fst . Map.keys . _facts) licenseGraph
  let licRaw = getLicRaw paramMap
  H.header $ do
    H.h1 (H.toMarkup licRaw)
    H.div H.! A.class_ "tab" $ do
      H.button H.! A.class_ "tablinks active" H.! A.onclick "openTab(event, 'content-graph')" $ "Graph"
      H.button H.! A.class_ "tablinks" H.! A.onclick "openTab(event, 'content-summary')" $ "Summary"
      H.button H.! A.class_ "tablinks" H.! A.onclick "openTab(event, 'content-policy')" $ "Policy"
    H.form H.! A.action "" $ do
      H.input H.! A.name "license" H.! A.id "license" H.! A.value (H.toValue licRaw) H.! A.list "licenses"
      H.datalist H.! A.id "licenses" $
        mapM_ (\license -> H.option H.! A.value (fromString $ show license) $ pure ()) allLicenseNames
      H.h4 "Sources"
      H.ul $
        mapM_
          ( \s@(Source source) -> H.li $ do
              H.input
                H.! A.type_ "checkbox"
                H.! A.name (fromString source)
                H.! A.value "on"
                H.! ( if isSourceEnabled paramMap (Source source)
                        then A.checked "checked"
                        else mempty
                    )
              let pureColour :: (Ord a, Fractional a) => Colour.AlphaColour a -> Colour.Colour a
                  pureColour ac
                    | a > 0 = Colour.darken (recip a) (ac `Colour.over` Colour.black)
                    | otherwise = error "transparent has no pure colour"
                    where
                      a = Colour.alphaChannel ac
              let color = (maybe "black" (Colour.sRGB24show . pureColour) . GV.toColour . typeColoringLookup) s
              H.label H.! A.for (fromString source) H.! A.style (fromString $ "color: " ++ color ++ "; font-weight: bold;") $ do
                fromString source
                H.a H.! A.href (H.toValue $ "/source" </> show s) $ " [*]"
          )
          allSources
      H.h4 "Graph Options"
      H.ul $ do
        H.li $ do
          H.input
            H.! A.type_ "checkbox"
            H.! A.name (H.toValue excludeStmts)
            H.! A.value "on"
            H.! ( if getIsExcludeStmts paramMap
                    then A.checked "checked"
                    else mempty
                )
          H.label H.! A.for (H.toValue excludeStmts) $ H.toMarkup excludeStmts
      H.input H.! A.type_ "submit" H.! A.value "reload" H.! A.name "reload"

      H.h3 "Other Links"
      H.ul $ do
        H.li $ do
          H.a H.! A.href "/clusters" $ "clusters"

dotSvgMarkup :: Digraph -> H.Markup
dotSvgMarkup digraph =
  let digraphDot = digraphToText digraph
   in do
        H.pre H.! A.id "graph.dot" H.! A.style "display:none;" $
          H.toMarkup digraphDot
        H.script $ do
          "d3.select(\".content\")"
          "    .graphviz()"
          "    .engine('fdp')"
          "    .zoomScaleExtent([1,30])"
          "    .fit(true)"
          "    .renderDot(document.getElementById('graph.dot').textContent);"

summaryContent :: LicenseGraph -> LicenseGraphType -> LicenseNameCluster -> H.Markup
summaryContent licenseGraph subgraph cluster = do 
    let facts =
          ( mapMaybe
              ( \case
                  LGFact f -> Just f
                  _ -> Nothing
                  . snd
              )
              . G.labNodes
          )
            subgraph
    H.h1 "Summary"
    licenseFactsImplicationsToMarkup facts cluster
    H.h1 "by Source"
    H.ul $
      mapM_
        ( \fact -> H.li $ do
            let factId = getFactId fact
            H.h3 $ do
              case getSourceOfFact licenseGraph factId of
                Just source -> do
                  H.a H.! A.href (H.toValue $ "/source" </> show source) $ H.toMarkup (show source)
                  ": "
                Nothing -> pure ()
              licenseFactUrl fact $ H.toMarkup factId
              " for "
              lnToA Nothing (getMainLicenseName fact)
            toMarkup fact
            H.details $ do
              H.summary "JSON:"
              H.pre (H.toMarkup (bsToText (BL.toStrict (encodePretty fact))))
        )
        facts

mainPage :: ParamMap -> LicenseGraph -> (LicenseGraphType, LicenseNameGraphType, (Digraph, SourceRef -> GV.Color), LicenseNameCluster) -> IO H.Html
mainPage paramMap licenseGraph (subgraph, lnsubgraph, (digraph, typeColoringLookup), cluster) = do
  let licRaw = getLicRaw paramMap
  return . H.html $ do
    htmlHead ("ldbcollector: " <> licRaw)
    H.body H.! A.class_ "fixed" $ do
      htmlHeader licenseGraph typeColoringLookup paramMap
      H.div H.! A.class_ "content active" H.! A.id "content-graph" H.! A.style "display: block;" $ do
        dotSvgMarkup digraph
      H.div H.! A.class_ "content" H.! A.id "content-summary" $ summaryContent licenseGraph subgraph cluster
      H.div H.! A.class_ "content" H.! A.id "content-policy" $ do
        "tbd."
      H.script H.! A.src "/script.js" $
        pure ()
      H.script "main();"

singleHtml :: T.Text ->  LicenseGraph -> LicenseGraphType -> LicenseNameCluster -> H.Html
singleHtml licRaw licenseGraph subgraph cluster =
  H.html $ do
    htmlHead' True ("ldbcollector: " <> licRaw)
    H.body $ do
      H.h1 (H.toMarkup licRaw)
      summaryContent licenseGraph subgraph cluster

writeSingleHtmlIO :: FilePath -> T.Text -> LicenseGraph -> LicenseGraphType -> LicenseNameCluster -> IO ()
writeSingleHtmlIO html licRaw licenseGraph subgraph cluster = do
  let page = singleHtml licRaw licenseGraph subgraph cluster
  I.writeFile html (BT.renderHtml page)

writeSingleHtml :: FilePath -> T.Text -> ([G.Node], [G.Node], [G.Node]) -> LicenseGraphM ()
writeSingleHtml html licRaw (needleNames, sameNames, otherNames) = do
    licenseGraph <- MTL.get
    (subgraph, lnsubgraph, (digraph, typeColoringLookup), cluster) <- extractSubgraph False (needleNames, sameNames, otherNames)
    lift $ writeSingleHtmlIO html licRaw licenseGraph subgraph cluster

getMyOptions :: IO S.Options
getMyOptions = do
  port <- maybe 3000 read <$> Env.lookupEnv "PORT"
  putStrLn ("PORT=" ++ show port)
  return $ S.Options 1 (Warp.setPort port (Warp.setFileInfoCacheDuration 3600 (Warp.setFdCacheDuration 3600 Warp.defaultSettings)))

serve :: LicenseGraphM ()
serve = do
  licenseGraph <- MTL.get
  clusters <- getClusters

  lift $ do
    cache <- C.newCache Nothing
    let init params = do
          paramMap <- evaluateParams params
          C.lookup cache (hash paramMap) >>= \case
            Just tuple -> return (paramMap, tuple)
            _ -> do
              tuple <- computeSubgraph licenseGraph paramMap
              C.insert cache (hash paramMap) tuple
              return (paramMap, tuple)
    myOptions <- getMyOptions
    scottyOpts myOptions $ do
      get "/styles.css" $ raw (BL.fromStrict stylesheet)
      get "/script.js" $ raw (BL.fromStrict scriptJs)
      get "/" $ do
        params <- S.params
        page <- liftAndCatchIO $ do
          (paramMap, tuple) <- init params
          mainPage paramMap licenseGraph tuple
        html (BT.renderHtml page)
      get "/dot" $ do
        params <- S.params
        dot <- liftAndCatchIO $ do
          (_, (_, _, (digraph, _), _)) <- init params
          return (digraphToText digraph)
        text dot
      get "/svg" $ do
        params <- S.params
        svg <- liftAndCatchIO $ do
          (_, (_, _, (digraph, _), _)) <- init params
          rederDotToText "fdp" digraph
        setHeader "Content-Type" "image/svg+xml"
        text svg
      get "/source/:source" $ do
        source <- fromString <$> param "source"
        page <- liftAndCatchIO $ printFactsForSource source licenseGraph
        html (BT.renderHtml page)
      get "/fact/:facttype/:facthash" $ do
        facttype <- fromString <$> param "facttype"
        facthash <- fromString <$> param "facthash"
        page <- liftAndCatchIO $ printFacts (FactId facttype facthash) licenseGraph
        html (BT.renderHtml page)
      get "/clusters" $ listPageAction clusters