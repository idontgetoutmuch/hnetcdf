{-# LANGUAGE TypeFamilies, FlexibleInstances, ScopedTypeVariables #-}

module Data.NetCDF
       ( module Data.NetCDF.Raw
       , module Data.NetCDF.Types
       , module Data.NetCDF.Metadata
       , IOMode (..)
       , openFile, closeFile, withFile
       , get1 ) where

import Data.NetCDF.Raw
import Data.NetCDF.Types
import Data.NetCDF.Metadata
import Data.NetCDF.Storable
import Data.NetCDF.Utils

import Control.Applicative ((<$>))
import Control.Exception (bracket)
import Control.Monad (forM, void)
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Either
import Data.List
import qualified Data.Map as M
import Foreign.C
import System.IO (IOMode (..))

-- | Open a NetCDF file and read all metadata.
openFile :: FilePath -> IOMode -> IO (Either NcError NcInfo)
openFile p mode = runEitherT $ runReaderT go ("openFile", p) where
  go :: Access NcInfo
  go = do
    ncid <- chk $ nc_open p (ncIOMode mode)
    (ndims, nvars, nattrs, unlim) <- chk $ nc_inq ncid
    dims <- forM [0..ndims-1] $ \dimid -> do
      (name, len) <- chk $ nc_inq_dim ncid dimid
      return $ NcDim name len (dimid == unlim)
    attrs <- forM [0..nattrs-1] $ \attid -> do
      n <- chk $ nc_inq_attname ncid ncGlobal attid
      (itype, len) <- chk $ nc_inq_att ncid ncGlobal n
      a <- readAttr ncid ncGlobal n (toEnum itype) len
      return a
    vars <- forM [0..nvars-1] $ \varid -> do
      (n, itype, nvdims, vdimids, nvatts) <- chk $ nc_inq_var ncid varid
      let vdims = map (dims !!) $ take nvdims vdimids
      vattrs <- forM [0..nvatts-1] $ \vattid -> do
        vn <- chk $ nc_inq_attname ncid varid vattid
        (aitype, alen) <- chk $ nc_inq_att ncid varid vn
        a <- readAttr ncid varid vn (toEnum aitype) alen
        return a
      let vattmap = foldl (\m a -> M.insert (ncAttrName a) a m) M.empty vattrs
      return $ NcVar n (toEnum itype) vdims vattmap
    let dimmap = foldl (\m d -> M.insert (ncDimName d) d m) M.empty dims
        attmap = foldl (\m a -> M.insert (ncAttrName a) a m) M.empty attrs
        varmap = foldl (\m v -> M.insert (ncVarName v) v m) M.empty vars
        varidmap = M.fromList $ zip (map ncVarName vars) [0..]
    return $ NcInfo p dimmap varmap attmap ncid varidmap

-- | Close a NetCDF file.
closeFile :: NcInfo -> IO ()
closeFile (NcInfo _ _ _ _ ncid _) = void $ nc_close ncid

-- | Bracket file use: a little different from the standard 'bracket'
-- function because of error handling.
withFile :: FilePath -> IOMode
         -> (NcInfo -> IO r) -> (NcError -> IO r) -> IO r
withFile p m ok err = bracket
                      (openFile p m)
                      (\lr -> case lr of
                          Left _ -> return ()
                          Right i -> closeFile i)
                      (\lr -> case lr of
                          Left e -> err e
                          Right i -> ok i)

-- | Read an attribute from a NetCDF variable with error handling.
readAttr :: Int -> Int -> String -> NcType -> Int -> Access NcAttr
readAttr nc var n NcChar l = readAttr' nc var n l nc_get_att_text
readAttr nc var n NcShort l = readAttr' nc var n l nc_get_att_short
readAttr nc var n NcInt l = readAttr' nc var n l nc_get_att_int
readAttr nc var n NcFloat l = readAttr' nc var n l nc_get_att_float
readAttr nc var n NcDouble l = readAttr' nc var n l nc_get_att_double
readAttr nc var n NcUInt l = readAttr' nc var n l nc_get_att_uint
readAttr _ _ n _ _ = return $ NcAttr n ([0] :: [CInt])

-- | Helper function for attribute reading.
readAttr' :: Show a => Int -> Int -> String -> Int
          -> (Int -> Int -> String -> Int -> IO (Int, [a])) -> Access NcAttr
readAttr' nc var n l rf = NcAttr n <$> (chk $ rf nc var n l)


get1 :: NcStorable a => NcInfo -> NcVar -> [Int] -> IO (Either NcError a)
get1 nc var idxs = runEitherT $ flip runReaderT ("get1", ncName nc) $ do
    let ncid = ncId nc
        vid = (ncVarIds nc) M.! (ncVarName var)
    v <- chk $ get_var1 ncid vid idxs
    return v

