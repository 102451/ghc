{-# OPTIONS -fvia-C #-}

-- test that the code generator can correctly compile code with
-- non-ASCII characters in it. (5.00 couldn't).

module Main (main, h�ll�_w�rld) where

main = h�ll�_w�rld

h�ll�_w�rld = print "h�ll�_w�rld\n"
